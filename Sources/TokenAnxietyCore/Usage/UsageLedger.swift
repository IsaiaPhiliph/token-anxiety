import Foundation

/// Usage per hour, project, model, price tier and effort, plus a summary of every session.
///
/// Kept by Token Anxiety itself, so the history outlives the services' own logs (Claude
/// Code deletes transcripts after 30 days by default). Hours are UTC: the local calendar
/// is applied when the figures are shown, so changing time zone moves nothing.
public struct UsageLedger: Sendable, Equatable {
    public struct Key: Hashable, Sendable, Codable {
        /// Hours since 1970-01-01 00:00 UTC.
        public var hour: Int
        public var provider: ProviderID
        public var project: String
        public var model: String
        public var tier: String
        public var effort: String

        public init(hour: Int, provider: ProviderID, project: String, model: String, tier: String = "", effort: String = "") {
            self.hour = hour
            self.provider = provider
            self.project = project
            self.model = model
            self.tier = tier
            self.effort = effort
        }

        public var date: Date { Date(timeIntervalSince1970: Double(hour) * 3600) }

        enum CodingKeys: String, CodingKey {
            case hour = "h", provider = "p", project = "j", model = "m", tier = "t", effort = "e"
        }
    }

    public internal(set) var buckets: [Key: TokenCounts] = [:]
    public internal(set) var sessions: [String: SessionSummary] = [:]
    /// Session names by `SessionSummary.id`; a name the user chose wins over a generated one.
    public internal(set) var titles: [String: SessionTitle] = [:]
    /// Content sizes per UTC day (days since 1970), from `ContentReader`.
    public internal(set) var content: [Int: ContentCounts] = [:]

    public init() {}

    public var isEmpty: Bool { buckets.isEmpty }
    public var firstDate: Date? { buckets.keys.map(\.hour).min().map { Date(timeIntervalSince1970: Double($0) * 3600) } }

    // MARK: Adding

    mutating func add(_ event: UsageEvent) {
        let hour = Int((event.date.timeIntervalSince1970 / 3600).rounded(.down))
        let key = Key(hour: hour, provider: event.provider, project: event.project, model: event.model,
                      tier: event.tier, effort: event.effort ?? "")
        buckets[key, default: .zero] += event.counts

        let id = SessionSummary.id(event.provider, event.session)
        var session = sessions[id] ?? SessionSummary(provider: event.provider, session: event.session,
                                                    project: event.project, date: event.date)
        session.add(event)
        sessions[id] = session
    }

    mutating func addContent(_ counts: ContentCounts, date: Date) {
        content[Int((date.timeIntervalSince1970 / 86_400).rounded(.down)), default: ContentCounts()] += counts
    }

    /// Content sizes of the days that start in `interval` (all when nil).
    public func content(in interval: DateInterval? = nil) -> ContentCounts {
        var total = ContentCounts()
        for (day, counts) in content {
            let start = Date(timeIntervalSince1970: Double(day) * 86_400)
            if let interval, !(interval.start...interval.end).contains(start.addingTimeInterval(43_200)) { continue }
            total += counts
        }
        return total
    }

    mutating func setTitle(_ title: String, provider: ProviderID, session: String, custom: Bool) {
        let id = SessionSummary.id(provider, session)
        if let current = titles[id], current.custom, !custom { return }
        titles[id] = SessionTitle(text: title, custom: custom)
    }

    public func title(of session: SessionSummary) -> String? { titles[session.id]?.text }
}

public struct SessionTitle: Codable, Sendable, Equatable {
    public var text: String
    public var custom: Bool
}

/// One conversation (a Claude Code session, a Codex thread with its subagents).
public struct SessionSummary: Codable, Sendable, Equatable, Identifiable {
    public var provider: ProviderID
    public var session: String
    public var project: String
    public var start: Date
    public var end: Date
    /// Counts by `PricedModel` key ("model" or "model|tier").
    public var models: [String: TokenCounts] = [:]
    /// Tokens by git branch.
    public var branches: [String: Int] = [:]
    public var agents: [String] = []
    public var efforts: [String: Int] = [:]
    public var entrypoint: String?
    /// The largest context of a single request.
    public var peakContext = 0
    public var lastContext = 0
    public var lastModel: String?

    public var id: String { Self.id(provider, session) }
    static func id(_ provider: ProviderID, _ session: String) -> String { "\(provider.rawValue):\(session)" }

    init(provider: ProviderID, session: String, project: String, date: Date) {
        self.provider = provider
        self.session = session
        self.project = project
        start = date
        end = date
    }

    public var counts: TokenCounts { models.values.reduce(.zero, +) }
    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public var totals: UsageTotals {
        var totals = UsageTotals()
        for (key, counts) in models {
            let (model, tier) = PricedModel.split(key)
            totals.add(counts, model: model, tier: tier)
        }
        return totals
    }

    /// The model with the most tokens.
    public var mainModel: String? {
        models.max { $0.value.total < $1.value.total }.map { PricedModel.split($0.key).model }
    }

    public var mainBranch: String? { branches.max { $0.value < $1.value }?.key }

    mutating func add(_ event: UsageEvent) {
        start = min(start, event.date)
        if event.date >= end {
            end = event.date
            if event.counts.requests > 0 {
                lastContext = event.counts.inputSide
                lastModel = event.model
            }
        }
        if project == ProjectNames.unknown { project = event.project }
        models[PricedModel.key(event.model, event.tier), default: .zero] += event.counts
        if let branch = event.branch { branches[branch, default: 0] += event.counts.total }
        if let effort = event.effort, event.counts.requests > 0 { efforts[effort, default: 0] += event.counts.requests }
        if let agent = event.agent, !agents.contains(agent) { agents.append(agent) }
        if entrypoint == nil { entrypoint = event.entrypoint }
        peakContext = max(peakContext, event.counts.inputSide)
    }
}

enum PricedModel {
    static func key(_ model: String, _ tier: String) -> String { tier.isEmpty ? model : "\(model)|\(tier)" }

    static func split(_ key: String) -> (model: String, tier: String) {
        guard let bar = key.lastIndex(of: "|") else { return (key, "") }
        return (String(key[..<bar]), String(key[key.index(after: bar)...]))
    }
}

/// Tokens with what they would cost through the API.
public struct UsageTotals: Sendable, Hashable {
    public var counts = TokenCounts()
    /// Dollars, for the tokens of models with a known price.
    public var cost = 0.0
    /// Tokens of models without a price, left out of `cost`.
    public var unpricedTokens = 0

    public init() {}

    public mutating func add(_ counts: TokenCounts, model: String, tier: String) {
        self.counts += counts
        if let cost = Pricing.cost(counts, model: model, tier: tier) {
            self.cost += cost
        } else {
            unpricedTokens += counts.total
        }
    }

    public static func + (lhs: UsageTotals, rhs: UsageTotals) -> UsageTotals {
        var sum = lhs
        sum.counts += rhs.counts
        sum.cost += rhs.cost
        sum.unpricedTokens += rhs.unpricedTokens
        return sum
    }
}

// MARK: Reading

public extension UsageLedger {
    /// Buckets that fall in `interval` (all when nil), from one service or all.
    func entries(in interval: DateInterval? = nil, provider: ProviderID? = nil) -> [(key: Key, counts: TokenCounts)] {
        let range = interval.map { hourRange($0) }
        return buckets.compactMap { key, counts in
            if let provider, key.provider != provider { return nil }
            if let range, !range.contains(key.hour) { return nil }
            return (key, counts)
        }
    }

    func totals(in interval: DateInterval? = nil, provider: ProviderID? = nil) -> UsageTotals {
        var totals = UsageTotals()
        for (key, counts) in entries(in: interval, provider: provider) {
            totals.add(counts, model: key.model, tier: key.tier)
        }
        return totals
    }

    /// Totals grouped by any part of the key: day, project, model…
    func grouped<G: Hashable>(in interval: DateInterval? = nil, provider: ProviderID? = nil,
                              by group: (Key) -> G) -> [G: UsageTotals] {
        var result: [G: UsageTotals] = [:]
        for (key, counts) in entries(in: interval, provider: provider) {
            result[group(key), default: UsageTotals()].add(counts, model: key.model, tier: key.tier)
        }
        return result
    }

    /// Totals per local day (the start of each day in `calendar`).
    func daily(in interval: DateInterval? = nil, provider: ProviderID? = nil,
               calendar: Calendar = .current) -> [Date: UsageTotals] {
        grouped(in: interval, provider: provider) { calendar.startOfDay(for: $0.date) }
    }

    /// Days with any usage, as the start of each local day.
    func activeDays(provider: ProviderID? = nil, calendar: Calendar = .current) -> Set<Date> {
        Set(entries(provider: provider).filter { $0.counts.total > 0 }.map { calendar.startOfDay(for: $0.key.date) })
    }

    /// Sessions active during `interval`, newest first.
    func sessions(in interval: DateInterval? = nil, provider: ProviderID? = nil) -> [SessionSummary] {
        sessions.values.filter { session in
            if let provider, session.provider != provider { return false }
            if let interval, session.end < interval.start || session.start > interval.end { return false }
            return true
        }.sorted { $0.end > $1.end }
    }

    /// Hours whose start lies in the interval (a bucket counts whole).
    private func hourRange(_ interval: DateInterval) -> ClosedRange<Int> {
        let first = Int((interval.start.timeIntervalSince1970 / 3600).rounded(.up))
        let last = Int(((interval.end.timeIntervalSince1970 - 1) / 3600).rounded(.down))
        return first...max(first, last)
    }
}

// MARK: Saving

extension UsageLedger: Codable {
    private struct Row: Codable {
        var key: Key
        var counts: TokenCounts

        enum CodingKeys: String, CodingKey { case key = "k", counts = "c" }
    }

    enum CodingKeys: String, CodingKey { case version, buckets, sessions, titles, content }

    static let version = 1

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .version) == Self.version else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "unknown ledger version")
        }
        for row in try c.decode([Row].self, forKey: .buckets) { buckets[row.key, default: .zero] += row.counts }
        for session in try c.decode([SessionSummary].self, forKey: .sessions) { sessions[session.id] = session }
        titles = try c.decode([String: SessionTitle].self, forKey: .titles)
        content = try c.decodeIfPresent([Int: ContentCounts].self, forKey: .content) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.version, forKey: .version)
        let rows = buckets.map { Row(key: $0.key, counts: $0.value) }
            .sorted { ($0.key.hour, $0.key.project, $0.key.model) < ($1.key.hour, $1.key.project, $1.key.model) }
        try c.encode(rows, forKey: .buckets)
        try c.encode(sessions.values.sorted { $0.start < $1.start }, forKey: .sessions)
        try c.encode(titles, forKey: .titles)
        try c.encode(content, forKey: .content)
    }
}
