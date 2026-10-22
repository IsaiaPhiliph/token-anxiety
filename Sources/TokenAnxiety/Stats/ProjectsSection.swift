import SwiftUI
import TokenAnxietyCore

/// Usage per project (the git repository a session ran in): a project × day map and a table.
struct ProjectsSection: View {
    let scope: StatsScope

    @State private var sortOrder = [KeyPathComparator(\ProjectRow.tokens, order: .reverse)]

    struct ProjectRow: Identifiable {
        var name: String
        var tokens: Int
        var cost: Double
        var share: Double
        var sessions: Int
        var last: Date
        var id: String { name }
    }

    private var rows: [ProjectRow] {
        let totals = scope.ledger.grouped(in: scope.interval, provider: scope.provider, by: \.project)
        let activity = scope.ledger.projectActivity(in: scope.interval, provider: scope.provider)
        let sum = max(1, scope.value(totals.values.reduce(UsageTotals(), +)))
        return totals.map { name, totals in
            ProjectRow(name: name, tokens: totals.counts.total, cost: totals.cost, share: scope.value(totals) / sum,
                       sessions: activity[name]?.sessions ?? 0, last: activity[name]?.last ?? .distantPast)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StatsCard(title: String(localized: "Projects day by day"),
                      subtitle: String(localized: "The busiest projects of the last \(matrixDays) days")) {
                matrix
            }
            Table(rows.sorted(using: sortOrder), sortOrder: $sortOrder) {
                TableColumn("Project", value: \.name) { row in
                    Text(row.name).fontWeight(.medium)
                }
                TableColumn("Tokens", value: \.tokens) { row in
                    Text(Fmt.tokens(Double(row.tokens))).monospacedDigit()
                }
                .width(min: 70, ideal: 90)
                TableColumn("≈ API cost", value: \.cost) { row in
                    Text(Fmt.money(row.cost)).monospacedDigit()
                }
                .width(min: 70, ideal: 90)
                TableColumn("Share", value: \.share) { row in
                    HStack(spacing: 6) {
                        UsageBar(value: row.share * 100, tint: .accentColor, height: 5)
                            .frame(width: 60)
                        Text(Fmt.percent(row.share * 100)).monospacedDigit()
                    }
                }
                .width(min: 100, ideal: 120)
                TableColumn("Sessions", value: \.sessions) { row in
                    Text(row.sessions.formatted(.number.locale(Fmt.locale))).monospacedDigit()
                }
                .width(min: 60, ideal: 70)
                TableColumn("Last used", value: \.last) { row in
                    Text(row.last == .distantPast ? "–" : Fmt.ago(row.last, now: scope.now))
                        .foregroundStyle(.secondary)
                }
                .width(min: 90, ideal: 110)
            }
            .frame(minHeight: 200)
        }
        .padding(24)
    }

    /// The map covers at least two weeks and at most 90 days, whatever the period.
    private var matrixDays: Int { max(14, min(90, scope.period.days ?? 90)) }

    private var matrix: some View {
        let today = scope.calendar.startOfDay(for: scope.now)
        let start = scope.calendar.date(byAdding: .day, value: -(matrixDays - 1), to: today) ?? today
        let interval = DateInterval(start: start, end: scope.now)
        let top = scope.ledger.topProjects(in: interval, provider: scope.provider, limit: 8)
        let other = String(localized: "Other projects")
        var cells: [String: [Double]] = [:]
        for (key, counts) in scope.ledger.entries(in: interval, provider: scope.provider) {
            var totals = UsageTotals()
            totals.add(counts, model: key.model, tier: key.tier)
            let name = top.contains(key.project) ? key.project : other
            let column = scope.calendar.dateComponents([.day], from: start, to: scope.calendar.startOfDay(for: key.date)).day ?? 0
            guard (0..<matrixDays).contains(column) else { continue }
            cells[name, default: Array(repeating: 0, count: matrixDays)][column] += scope.value(totals)
        }
        let names = top + (cells[other] == nil ? [] : [other])
        let rows = names.map { MatrixHeatmap.Row(label: $0, values: cells[$0] ?? [], tint: $0 == other ? .gray : .accentColor) }
        let day = { (column: Int) in scope.calendar.date(byAdding: .day, value: column, to: start) ?? start }
        let step = matrixDays > 30 ? 14 : 7
        let labels = Dictionary(uniqueKeysWithValues: stride(from: 0, to: matrixDays, by: step).map { ($0, Fmt.day(day($0))) })
        return MatrixHeatmap(rows: rows, columnLabels: labels) { row, column in
            "\(rows[row].label) · \(Fmt.day(day(column))): \(scope.format(column < rows[row].values.count ? rows[row].values[column] : 0))"
        }
    }
}
