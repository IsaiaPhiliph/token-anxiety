import Charts
import SwiftUI
import TokenAnxietyCore

extension TokenKind {
    var title: String {
        switch self {
        case .input: String(localized: "Input")
        case .output: String(localized: "Output")
        case .cacheWrite: String(localized: "Cache writes")
        case .cacheRead: String(localized: "Cache reads")
        }
    }

    var color: Color {
        switch self {
        case .input: .blue
        case .output: .orange
        case .cacheWrite: .purple
        case .cacheRead: .teal
        }
    }
}

/// A titled block on the window's background.
struct StatsCard<Content: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary.opacity(0.5)))
    }
}

/// One headline figure, with its change against the previous period.
struct StatTile: View {
    var title: String
    var value: String
    var symbol: String
    var change: Double?
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            HStack(spacing: 4) {
                if let change { ChangeBadge(change: change) }
                if let footnote {
                    Text(footnote)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(minHeight: 14)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary.opacity(0.5)))
    }
}

/// "+12 %" against the previous period. Neutral colours: more use is neither good nor bad.
struct ChangeBadge: View {
    var change: Double

    var body: some View {
        let rounded = (change * 100).rounded()
        HStack(spacing: 2) {
            Image(systemName: rounded > 0 ? "arrow.up.right" : rounded < 0 ? "arrow.down.right" : "equal")
            Text(Fmt.percent(abs(rounded)))
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .foregroundStyle(.secondary)
        .help("Compared with the previous period")
    }

    /// nil when there is nothing to compare with.
    static func change(_ current: Double, _ previous: Double) -> Double? {
        previous > 0 ? current / previous - 1 : nil
    }
}

/// A year of days as squares, a week per column, darker the more was used.
struct ActivityHeatmap: View {
    let values: [Date: Double]
    let calendar: Calendar
    let now: Date
    let format: (Double) -> String
    var weeks = 53
    var maxCell: CGFloat = 14

    var body: some View {
        let today = calendar.startOfDay(for: now)
        let weekdayIndex = (calendar.component(.weekday, from: today) - calendar.firstWeekday + 7) % 7
        let firstColumnStart = calendar.date(byAdding: .day, value: -(weeks - 1) * 7 - weekdayIndex, to: today) ?? today
        let levels = Self.levels(values.values.filter { $0 > 0 })
        GeometryReader { proxy in
            let gap: CGFloat = 3
            let size = max(4, (proxy.size.width - gap * CGFloat(weeks - 1)) / CGFloat(weeks))
            HStack(alignment: .top, spacing: gap) {
                ForEach(0..<weeks, id: \.self) { week in
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { weekday in
                            let day = calendar.date(byAdding: .day, value: week * 7 + weekday, to: firstColumnStart) ?? today
                            let value = values[day] ?? 0
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(day > today ? Color.clear : Self.color(level: Self.level(value, levels)))
                                .frame(width: size, height: size)
                                .help(day > today ? "" : "\(Fmt.day(day)): \(format(value))")
                        }
                    }
                }
            }
        }
        .aspectRatio(CGFloat(weeks * 13 - 3) / CGFloat(7 * 13 - 3), contentMode: .fit)
        .frame(maxWidth: CGFloat(weeks) * (maxCell + 3) - 3)
    }

    /// Quartiles of the active days, so a few huge days do not wash out the rest.
    static func levels(_ values: [Double]) -> [Double] {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return [] }
        return [0.25, 0.5, 0.75].map { sorted[min(sorted.count - 1, Int(Double(sorted.count) * $0))] }
    }

    static func level(_ value: Double, _ levels: [Double]) -> Int {
        guard value > 0 else { return 0 }
        return 1 + levels.filter { value > $0 }.count
    }

    static func color(level: Int) -> Color {
        level == 0 ? Color.primary.opacity(0.07) : Color.accentColor.opacity([0, 0.3, 0.5, 0.72, 1][level])
    }
}

extension View {
    /// Y axis labels in tokens or dollars.
    func statsValueAxis(_ scope: StatsScope) -> some View {
        chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel { Text(scope.format(value.as(Double.self) ?? 0)) }
            }
        }
    }
}

/// Rows of cells, darker the larger the value: projects by day, weekdays by hour.
struct MatrixHeatmap: View {
    struct Row: Identifiable {
        var label: String
        var values: [Double]
        var tint: Color = .accentColor
        var id: String { label }
    }

    let rows: [Row]
    /// Labels under some of the columns.
    let columnLabels: [Int: String]
    let tooltip: (Int, Int) -> String
    var cellHeight: CGFloat = 18
    var labelWidth: CGFloat = 130

    private let gap: CGFloat = 3

    var body: some View {
        let columns = rows.map(\.values.count).max() ?? 0
        let highest = rows.flatMap(\.values).max() ?? 0
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: gap) {
                ForEach(rows) { row in
                    Text(row.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(height: cellHeight)
                }
            }
            .frame(width: labelWidth, alignment: .trailing)
            GeometryReader { proxy in
                let width = max(2, (proxy.size.width - gap * CGFloat(max(columns - 1, 0))) / CGFloat(max(columns, 1)))
                VStack(alignment: .leading, spacing: gap) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { rowIndex, row in
                        HStack(spacing: gap) {
                            ForEach(0..<columns, id: \.self) { column in
                                let value = column < row.values.count ? row.values[column] : 0
                                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                    .fill(value > 0 && highest > 0
                                          ? row.tint.opacity(0.15 + 0.85 * sqrt(value / highest))
                                          : Color.primary.opacity(0.06))
                                    .frame(width: width, height: cellHeight)
                                    .help(tooltip(rowIndex, column))
                            }
                        }
                    }
                    ZStack(alignment: .topLeading) {
                        ForEach(columnLabels.sorted(by: { $0.key < $1.key }), id: \.key) { column, label in
                            Text(label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .offset(x: CGFloat(column) * (width + gap))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: CGFloat(rows.count) * (cellHeight + gap) + 16)
        }
    }
}
