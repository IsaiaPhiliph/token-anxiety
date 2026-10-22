import Foundation

/// How full the context window of each live Claude Code session is: the input of its
/// last request (cached or not) over the model's window.
public struct ContextGauge: Sendable, Equatable, Identifiable {
    public var session: String
    public var title: String
    public var model: String
    public var tokens: Int
    public var window: Int
    public var updated: Date

    public var id: String { session }
    public var percent: Double { window > 0 ? min(100, Double(tokens) / Double(window) * 100) : 0 }

    /// Sessions with a request in the last `recent` seconds, fullest first.
    public static func live(in ledger: UsageLedger, now: Date = Date(), recent: TimeInterval = 15 * 60,
                            limit: Int = 3) -> [ContextGauge] {
        ledger.sessions.values
            .filter { $0.provider == .claude && $0.lastContext > 0 && now.timeIntervalSince($0.end) < recent }
            .map { session in
                let model = session.lastModel ?? ""
                return ContextGauge(session: session.id, title: ledger.title(of: session) ?? session.project, model: model,
                                    tokens: session.lastContext, window: window(model: model, seen: session.lastContext),
                                    updated: session.end)
            }
            .sorted { $0.percent > $1.percent }
            .prefix(limit)
            .map { $0 }
    }

    /// The model's context window: 1M for Claude 4.6 and later (and any "[1m]" id), 200K before.
    /// A request already past 200K proves the larger window.
    public static func window(model: String, seen: Int = 0) -> Int {
        if model.lowercased().contains("[1m]") || seen > 200_000 { return 1_000_000 }
        let id = Pricing.canonical(model)
        let small = ["opus-4-5", "opus-4-1", "opus-4-2", "sonnet-4-5", "sonnet-4-2", "haiku-4-5", "claude-3"]
        if small.contains(where: { id.contains($0) }) || id.hasSuffix("opus-4") || id.hasSuffix("sonnet-4") { return 200_000 }
        return id.contains("claude") ? 1_000_000 : 200_000
    }
}
