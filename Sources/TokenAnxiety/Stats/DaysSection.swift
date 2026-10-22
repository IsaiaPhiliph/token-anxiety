import Charts
import SwiftUI
import TokenAnxietyCore

enum DayStack: String, CaseIterable, Identifiable {
    case kind, model, project, service

    var id: String { rawValue }

    var title: String {
        switch self {
        case .kind: String(localized: "Token type")
        case .model: String(localized: "Model")
        case .project: String(localized: "Project")
        case .service: String(localized: "Service")
        }
    }
}

/// Usage per day (per hour for today), stacked by token type, model, project or service.
struct DaysSection: View {
    let scope: StatsScope

    @AppStorage("stats.days.stack") private var stack: DayStack = .model
    @State private var selected: Date?

    private struct Bar: Identifiable {
        var date: Date
        var series: String
        var value: Double
        var order: Int
        var id: String { "\(date.timeIntervalSince1970)-\(series)" }
    }

    /// Hourly bars for today, daily ones otherwise.
    private var unit: Calendar.Component { scope.period == .today ? .hour : .day }

    private func slot(_ date: Date) -> Date {
        unit == .hour ? scope.calendar.dateInterval(of: .hour, for: date)?.start ?? date : scope.calendar.startOfDay(for: date)
    }

    private var bars: [Bar] {
        let entries = scope.ledger.entries(in: scope.interval, provider: scope.provider)
        let topProjects = Set(scope.ledger.topProjects(in: scope.interval, provider: scope.provider, limit: 6))
        var sums: [Date: [String: (order: Int, totals: UsageTotals)]] = [:]
        func add(_ date: Date, _ series: String, _ order: Int, _ counts: TokenCounts, _ key: UsageLedger.Key) {
            var slotSums = sums[date, default: [:]]
            var entry = slotSums[series] ?? (order, UsageTotals())
            entry.totals.add(counts, model: key.model, tier: key.tier)
            slotSums[series] = entry
            sums[date] = slotSums
        }
        for (key, counts) in entries {
            let date = slot(key.date)
            switch stack {
            case .kind:
                for (index, kind) in TokenKind.allCases.enumerated() where counts.tokens(kind) > 0 {
                    add(date, kind.title, index, counts.only(kind), key)
                }
            case .model:
                add(date, ModelNames.display(key.model), 0, counts, key)
            case .project:
                let project = topProjects.contains(key.project) ? key.project : String(localized: "Other projects")
                add(date, project, topProjects.contains(key.project) ? 0 : 1, counts, key)
            case .service:
                add(date, key.provider.displayName, key.provider == .claude ? 0 : 1, counts, key)
            }
        }
        return sums.flatMap { date, series in
            series.map { Bar(date: date, series: $0.key, value: scope.value($0.value.totals), order: $0.value.order) }
        }
        .sorted { ($0.order, $0.series) < ($1.order, $1.series) }
    }

    var body: some View {
        let bars = bars
        let perSlot = Dictionary(grouping: bars, by: \.date).mapValues { $0.reduce(0) { $0 + $1.value } }
        VStack(alignment: .leading, spacing: 18) {
            StatsCard(title: unit == .hour ? String(localized: "Today, hour by hour") : String(localized: "Day by day"),
                      subtitle: scope.valueLabel) {
                Picker("Stack by", selection: $stack) {
                    ForEach(DayStack.allCases) { stack in Text(stack.title).tag(stack) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)
                Chart {
                    ForEach(bars) { bar in
                        BarMark(x: .value("Date", bar.date, unit: unit), y: .value("Value", bar.value))
                            .foregroundStyle(by: .value("Series", bar.series))
                    }
                    if let selected, let total = perSlot[slot(selected)] {
                        RuleMark(x: .value("Date", slot(selected), unit: unit))
                            .foregroundStyle(Color.primary.opacity(0.15))
                            .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                tooltip(slot(selected), total: total, bars: bars.filter { $0.date == slot(selected) })
                            }
                    }
                }
                .chartForegroundStyleScale(domain: seriesDomain(bars), range: seriesColors(bars))
                .chartXSelection(value: $selected)
                .statsValueAxis(scope)
                .frame(height: 300)
            }
            summary(perSlot)
        }
    }

    private func seriesDomain(_ bars: [Bar]) -> [String] {
        var seen: [String] = []
        for bar in bars where !seen.contains(bar.series) { seen.append(bar.series) }
        return seen
    }

    private func seriesColors(_ bars: [Bar]) -> [Color] {
        let domain = seriesDomain(bars)
        if stack == .kind {
            return domain.map { name in TokenKind.allCases.first { $0.title == name }?.color ?? .gray }
        }
        let palette: [Color] = [.accentColor, .orange, .purple, .teal, .pink, .green, .yellow, .indigo, .brown]
        return domain.enumerated().map { index, name in
            name == String(localized: "Other projects") ? .gray : palette[index % palette.count]
        }
    }

    private func tooltip(_ date: Date, total: Double, bars: [Bar]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(unit == .hour ? Fmt.time(date) : Fmt.day(date))
                .font(.caption.weight(.semibold))
            Text(scope.format(total))
                .font(.caption.monospacedDigit())
            ForEach(bars.sorted { $0.value > $1.value }.prefix(6)) { bar in
                HStack {
                    Text(bar.series)
                    Spacer(minLength: 12)
                    Text(scope.format(bar.value)).monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background).shadow(radius: 3))
        .frame(width: 200)
    }

    @ViewBuilder
    private func summary(_ perSlot: [Date: Double]) -> some View {
        let active = perSlot.filter { $0.value > 0 }
        if let busiest = active.max(by: { $0.value < $1.value }) {
            let average = active.values.reduce(0, +) / Double(active.count)
            HStack(spacing: 12) {
                StatTile(title: unit == .hour ? String(localized: "Busiest hour") : String(localized: "Busiest day"),
                         value: scope.format(busiest.value), symbol: "flame",
                         footnote: unit == .hour ? Fmt.time(busiest.key) : Fmt.day(busiest.key))
                StatTile(title: unit == .hour ? String(localized: "Average active hour") : String(localized: "Average active day"),
                         value: scope.format(average), symbol: "chart.line.flattrend.xyaxis",
                         footnote: String(localized: "\(active.count) with usage"))
            }
        }
    }
}
