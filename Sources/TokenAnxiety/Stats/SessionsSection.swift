import SwiftUI
import TokenAnxietyCore

/// Every conversation in the period, with what it used.
struct SessionsSection: View {
    let scope: StatsScope

    @State private var sortOrder = [KeyPathComparator(\SessionRow.end, order: .reverse)]
    @State private var search = ""

    struct SessionRow: Identifiable {
        var id: String
        var title: String
        var project: String
        var branch: String
        var model: String
        var provider: ProviderID
        var start: Date
        var end: Date
        var duration: TimeInterval
        var tokens: Int
        var cost: Double
        var requests: Int
        var agents: Int
    }

    private var rows: [SessionRow] {
        scope.ledger.sessions(in: scope.interval, provider: scope.provider).map { session in
            let totals = session.totals
            return SessionRow(id: session.id, title: scope.ledger.title(of: session) ?? String(localized: "Untitled"),
                              project: session.project, branch: session.mainBranch ?? "",
                              model: session.mainModel.map(ModelNames.display) ?? "–", provider: session.provider,
                              start: session.start, end: session.end, duration: session.duration,
                              tokens: totals.counts.total, cost: totals.cost, requests: totals.counts.requests,
                              agents: session.agents.count)
        }
        .filter { row in
            search.isEmpty || [row.title, row.project, row.branch, row.model].contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        let rows = rows.sorted(using: sortOrder)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(rows.count) sessions · \(Fmt.tokens(Double(rows.reduce(0) { $0 + $1.tokens }))) tokens · \(Fmt.money(rows.reduce(0) { $0 + $1.cost }))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("Search", text: $search, prompt: Text("Title, project, branch or model"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }
            Table(rows, sortOrder: $sortOrder) {
                TableColumn("Session", value: \.title) { row in
                    HStack(spacing: 6) {
                        ProviderIcon(id: row.provider, size: 16)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(row.title).lineLimit(1)
                            if row.agents > 0 {
                                Text(row.agents == 1 ? String(localized: "1 subagent") : String(localized: "\(row.agents) subagents"))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .help(row.title)
                }
                .width(min: 130, ideal: 175)
                TableColumn("Project", value: \.project) { row in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.project).lineLimit(1)
                        if !row.branch.isEmpty {
                            Text(row.branch).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .width(min: 90, ideal: 120)
                TableColumn("Model", value: \.model)
                    .width(min: 60, ideal: 75)
                TableColumn("Started", value: \.start) { row in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Fmt.moment(row.start, now: scope.now)).lineLimit(1)
                        Text(row.duration < 60 ? "<1 min" : Fmt.duration(row.duration))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .width(min: 90, ideal: 110)
                TableColumn("Tokens", value: \.tokens) { row in
                    Text(Fmt.tokens(Double(row.tokens))).monospacedDigit()
                }
                .width(min: 55, ideal: 65)
                TableColumn("≈ API cost", value: \.cost) { row in
                    Text(Fmt.money(row.cost)).monospacedDigit()
                }
                .width(min: 60, ideal: 80)
            }
            Text("A session's figures are its whole conversation, also outside the period.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
    }
}
