import SwiftUI
import TokenAnxietyCore

struct OverviewSection: View {
    let scope: StatsScope
    let store: UsageStore

    var body: some View {
        let totals = scope.totals
        let previous = scope.previous.map { scope.ledger.totals(in: $0, provider: scope.provider) }
        let sessions = scope.ledger.sessions(in: scope.interval, provider: scope.provider)
        let previousSessions = scope.previous.map { scope.ledger.sessions(in: $0, provider: scope.provider).count }
        let activeDays = scope.ledger.daily(in: scope.interval, provider: scope.provider, calendar: scope.calendar)
            .filter { $0.value.counts.total > 0 }.count
        VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                StatTile(title: String(localized: "Tokens"), value: Fmt.tokens(Double(totals.counts.total)), symbol: "sum",
                         change: previous.flatMap { ChangeBadge.change(Double(totals.counts.total), Double($0.counts.total)) })
                StatTile(title: String(localized: "≈ API cost"), value: Fmt.money(totals.cost), symbol: "dollarsign.circle",
                         change: previous.flatMap { ChangeBadge.change(totals.cost, $0.cost) },
                         footnote: totals.unpricedTokens > 0 ? String(localized: "\(Fmt.tokens(Double(totals.unpricedTokens))) unpriced") : nil)
                StatTile(title: String(localized: "Requests"), value: totals.counts.requests.formatted(.number.locale(Fmt.locale)),
                         symbol: "arrow.up.arrow.down",
                         change: previous.flatMap { ChangeBadge.change(Double(totals.counts.requests), Double($0.counts.requests)) })
                StatTile(title: String(localized: "Sessions"), value: sessions.count.formatted(.number.locale(Fmt.locale)),
                         symbol: "bubble.left.and.bubble.right",
                         change: previousSessions.flatMap { ChangeBadge.change(Double(sessions.count), Double($0)) })
                StatTile(title: String(localized: "From the cache"), value: totals.counts.cacheHitRate.map { Fmt.percent($0 * 100) } ?? "–",
                         symbol: "memorychip", footnote: String(localized: "of the input"))
                StatTile(title: String(localized: "Active days"), value: activeDays.formatted(.number.locale(Fmt.locale)),
                         symbol: "calendar", footnote: streakText)
            }
            worthCards
            StatsCard(title: String(localized: "Activity"), subtitle: String(localized: "The last 12 months, one square a day")) {
                ActivityHeatmap(values: scope.ledger.daily(provider: scope.provider, calendar: scope.calendar)
                                    .mapValues { scope.value($0) },
                                calendar: scope.calendar, now: scope.now, format: scope.format)
            }
            historyNote
        }
    }

    private var streakText: String {
        let streaks = scope.ledger.streaks(now: scope.now, provider: scope.provider, calendar: scope.calendar)
        return String(localized: "Streak: \(streaks.current) · best \(streaks.longest)")
    }

    /// What each plan's current week would cost through the API.
    @ViewBuilder
    private var worthCards: some View {
        let providers = [ProviderID.claude, .codex].filter { scope.provider == nil || scope.provider == $0 }
        let worths = providers.compactMap { id -> (ProviderID, WeekWorth)? in
            guard let window = store.entries[id]?.snapshot?.secondary,
                  let worth = WeekWorth.estimate(window: window, ledger: scope.ledger, provider: id, now: scope.now) else { return nil }
            return (id, worth)
        }
        if !worths.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                ForEach(worths, id: \.0) { id, worth in
                    StatsCard(title: String(localized: "What your \(id.displayName) week is worth"),
                              subtitle: String(localized: "At API prices, from the tokens used since the week began")) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(Fmt.money(worth.full))
                                .font(.system(size: 26, weight: .semibold, design: .rounded))
                            Text("for the whole week")
                                .foregroundStyle(.secondary)
                        }
                        Text("\(Fmt.money(worth.spent)) so far, at \(Fmt.percent(worth.usedPercent)) of the weekly limit.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var historyNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                if let first = scope.ledger.firstDate {
                    Text("History since \(Fmt.day(first)). Costs are estimates at API prices, not what your plan charges.")
                }
                Text("Claude Code deletes its logs after 30 days; Token Anxiety keeps its own totals from the day it first read them. To keep more in Claude Code too, set \"cleanupPeriodDays\" in ~/.claude/settings.json.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
