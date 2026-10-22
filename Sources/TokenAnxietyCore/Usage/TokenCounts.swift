import Foundation

/// Tokens and requests, summed over any slice of the local logs.
///
/// `input` is the uncached input only: cache writes and reads are kept apart
/// because they cost differently. For Codex, whose logs count cached input as
/// part of the input, the cached part is moved to `cacheRead` when reading.
public struct TokenCounts: Sendable, Hashable {
    public var input = 0
    public var output = 0
    public var cacheWrite5m = 0
    public var cacheWrite1h = 0
    public var cacheRead = 0
    /// Part of `output` spent on reasoning (Codex reports it).
    public var reasoning = 0
    public var requests = 0
    public var webSearches = 0

    public init(input: Int = 0, output: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0,
                cacheRead: Int = 0, reasoning: Int = 0, requests: Int = 0, webSearches: Int = 0) {
        self.input = input
        self.output = output
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.reasoning = reasoning
        self.requests = requests
        self.webSearches = webSearches
    }

    public static let zero = TokenCounts()

    public var cacheWrite: Int { cacheWrite5m + cacheWrite1h }
    /// Everything the model read or wrote.
    public var total: Int { input + output + cacheWrite + cacheRead }
    /// What the model read in a request: its context.
    public var inputSide: Int { input + cacheWrite + cacheRead }
    public var isEmpty: Bool { total == 0 && requests == 0 }

    /// The share of the input that came from the cache.
    public var cacheHitRate: Double? {
        inputSide > 0 ? Double(cacheRead) / Double(inputSide) : nil
    }

    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        var sum = lhs
        sum += rhs
        return sum
    }

    public static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs.input += rhs.input
        lhs.output += rhs.output
        lhs.cacheWrite5m += rhs.cacheWrite5m
        lhs.cacheWrite1h += rhs.cacheWrite1h
        lhs.cacheRead += rhs.cacheRead
        lhs.reasoning += rhs.reasoning
        lhs.requests += rhs.requests
        lhs.webSearches += rhs.webSearches
    }

    /// What `other` adds over `self`, field by field (a response logged again with more output).
    public func growth(to other: TokenCounts) -> TokenCounts {
        TokenCounts(input: max(0, other.input - input), output: max(0, other.output - output),
                    cacheWrite5m: max(0, other.cacheWrite5m - cacheWrite5m),
                    cacheWrite1h: max(0, other.cacheWrite1h - cacheWrite1h),
                    cacheRead: max(0, other.cacheRead - cacheRead), reasoning: max(0, other.reasoning - reasoning),
                    requests: max(0, other.requests - requests), webSearches: max(0, other.webSearches - webSearches))
    }
}

extension TokenCounts: Codable {
    // Short keys, and zeros left out: the ledger holds thousands of these.
    private enum CodingKeys: String, CodingKey {
        case input = "i", output = "o", cacheWrite5m = "w", cacheWrite1h = "W", cacheRead = "r"
        case reasoning = "x", requests = "n", webSearches = "s"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decodeIfPresent(Int.self, forKey: .input) ?? 0
        output = try c.decodeIfPresent(Int.self, forKey: .output) ?? 0
        cacheWrite5m = try c.decodeIfPresent(Int.self, forKey: .cacheWrite5m) ?? 0
        cacheWrite1h = try c.decodeIfPresent(Int.self, forKey: .cacheWrite1h) ?? 0
        cacheRead = try c.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
        reasoning = try c.decodeIfPresent(Int.self, forKey: .reasoning) ?? 0
        requests = try c.decodeIfPresent(Int.self, forKey: .requests) ?? 0
        webSearches = try c.decodeIfPresent(Int.self, forKey: .webSearches) ?? 0
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        for (key, value) in [(CodingKeys.input, input), (.output, output), (.cacheWrite5m, cacheWrite5m),
                             (.cacheWrite1h, cacheWrite1h), (.cacheRead, cacheRead), (.reasoning, reasoning),
                             (.requests, requests), (.webSearches, webSearches)] where value != 0 {
            try c.encode(value, forKey: key)
        }
    }
}

/// One model request as read from a log, before it lands in the ledger.
public struct UsageEvent: Codable, Sendable, Hashable {
    public var provider: ProviderID
    public var date: Date
    public var session: String
    public var project: String
    public var branch: String?
    public var model: String
    /// Which price applies to this request: "" (standard), "fast" or "long" (see `Pricing`).
    public var tier: String
    public var effort: String?
    /// A subagent's id, when the request came from one.
    public var agent: String?
    /// Where Claude Code ran (desktop app, VS Code, terminal…).
    public var entrypoint: String?
    public var counts: TokenCounts

    public init(provider: ProviderID, date: Date, session: String, project: String, branch: String? = nil,
                model: String, tier: String = "", effort: String? = nil, agent: String? = nil,
                entrypoint: String? = nil, counts: TokenCounts) {
        self.provider = provider
        self.date = date
        self.session = session
        self.project = project
        self.branch = branch
        self.model = model
        self.tier = tier
        self.effort = effort
        self.agent = agent
        self.entrypoint = entrypoint
        self.counts = counts
    }
}
