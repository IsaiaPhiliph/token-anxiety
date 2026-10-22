import Charts
import SwiftUI
import TokenAnxietyCore

/// Which models did the work, at what effort, and where Claude Code ran.
struct ModelsSection: View {
    let scope: StatsScope

    private struct Slice: Identifiable {
        var name: String
        var totals: UsageTotals
        var value: Double
        var id: String { name }
    }

    var body: some View {
        let grouped = scope.ledger.grouped(in: scope.interval, provider: scope.provider) { ModelNames.display($0.model) }
        let slices = grouped.map { Slice(name: $0.key, totals: $0.value, value: scope.value($0.value)) }
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
        let sum = slices.reduce(0) { $0 + $1.value }
        VStack(alignment: .leading, spacing: 18) {
            StatsCard(title: String(localized: "By model"), subtitle: scope.valueLabel) {
                HStack(alignment: .center, spacing: 28) {
                    Chart(slices) { slice in
                        SectorMark(angle: .value("Value", slice.value), innerRadius: .ratio(0.62), angularInset: 1.5)
                            .foregroundStyle(by: .value("Model", slice.name))
                            .cornerRadius(3)
                    }
                    .chartLegend(.hidden)
                    .chartForegroundStyleScale(domain: slices.map(\.name), range: slices.indices.map(Self.color))
                    .frame(width: 190, height: 190)
                    .overlay {
                        VStack(spacing: 0) {
                            Text(scope.format(sum)).font(.title3.weight(.semibold))
                            Text(scope.valueLabel).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                        GridRow {
                            Text("Model")
                            Text("Tokens").gridColumnAlignment(.trailing)
                            Text("≈ API cost").gridColumnAlignment(.trailing)
                            Text("Requests").gridColumnAlignment(.trailing)
                            Text("Share").gridColumnAlignment(.trailing)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        ForEach(slices) { slice in
                            GridRow {
                                HStack(spacing: 6) {
                                    Circle().fill(Self.color(slices.firstIndex { $0.id == slice.id } ?? 0)).frame(width: 8, height: 8)
                                    Text(slice.name).fontWeight(.medium)
                                }
                                Text(Fmt.tokens(Double(slice.totals.counts.total)))
                                Text(slice.totals.unpricedTokens > 0 ? String(localized: "no price") : Fmt.money(slice.totals.cost))
                                    .foregroundStyle(slice.totals.unpricedTokens > 0 ? .secondary : .primary)
                                Text(slice.totals.counts.requests.formatted(.number.locale(Fmt.locale)))
                                Text(sum > 0 ? Fmt.percent(slice.value / sum * 100) : "–")
                            }
                            .monospacedDigit()
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                StatsCard(title: String(localized: "By effort"), subtitle: String(localized: "Requests at each reasoning effort")) {
                    efforts
                }
                StatsCard(title: String(localized: "Where Claude Code ran"), subtitle: String(localized: "Sessions by app")) {
                    entrypoints
                }
            }
        }
    }

    private var efforts: some View {
        let order = ["minimal", "low", "medium", "high", "xhigh", "max"]
        let grouped = scope.ledger.grouped(in: scope.interval, provider: scope.provider) { $0.effort }
        let rows = grouped.filter { !$0.key.isEmpty && $0.value.counts.requests > 0 }
            .map { (effort: $0.key, requests: $0.value.counts.requests) }
            .sorted { (order.firstIndex(of: $0.effort) ?? 99, $0.effort) < (order.firstIndex(of: $1.effort) ?? 99, $1.effort) }
        return Group {
            if rows.isEmpty {
                Text("The logs did not say.").font(.callout).foregroundStyle(.secondary)
            } else {
                let most = rows.map(\.requests).max() ?? 1
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rows, id: \.effort) { row in
                        HStack {
                            Text(row.effort)
                            Spacer()
                            Text(row.requests.formatted(.number.locale(Fmt.locale))).monospacedDigit().foregroundStyle(.secondary)
                        }
                        UsageBar(value: Double(row.requests) / Double(max(1, most)) * 100, tint: .accentColor, height: 5)
                    }
                }
            }
        }
    }

    private var entrypoints: some View {
        let sessions = scope.ledger.sessions(in: scope.interval, provider: .claude)
        let grouped = Dictionary(grouping: sessions) { Self.entrypointName($0.entrypoint) }
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
        return Group {
            if grouped.isEmpty || scope.provider == .codex {
                Text("Only Claude Code says where it ran.").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(grouped, id: \.name) { row in
                        HStack {
                            Text(row.name)
                            Spacer()
                            Text(row.count.formatted(.number.locale(Fmt.locale))).monospacedDigit().foregroundStyle(.secondary)
                        }
                        UsageBar(value: Double(row.count) / Double(max(1, sessions.count)) * 100, tint: .accentColor, height: 5)
                    }
                }
            }
        }
    }

    static func color(_ index: Int) -> Color {
        [Color.accentColor, .orange, .purple, .green, .pink, .teal, .yellow, .indigo][index % 8]
    }

    static func entrypointName(_ raw: String?) -> String {
        switch raw {
        case "claude-desktop": String(localized: "Claude app")
        case "claude-vscode": "VS Code"
        case "cli": String(localized: "Terminal")
        case let other? where other.hasPrefix("sdk"): String(localized: "Agent SDK")
        case let other?: other
        case nil: String(localized: "Unknown")
        }
    }
}
