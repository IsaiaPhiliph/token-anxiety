import Foundation

/// What a model costs per million tokens through its maker's API.
public struct ModelPrice: Sendable, Hashable {
    public var input: Double
    public var output: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double
    public var cacheRead: Double

    public init(input: Double, output: Double, cacheWrite5m: Double, cacheWrite1h: Double, cacheRead: Double) {
        self.input = input
        self.output = output
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
    }

    /// Anthropic's usual cache multipliers: writes at 1.25x (5 min) and 2x (1 h), reads at `read`x.
    static func claude(_ input: Double, _ output: Double, read: Double = 0.1) -> ModelPrice {
        ModelPrice(input: input, output: output, cacheWrite5m: input * 1.25, cacheWrite1h: input * 2,
                   cacheRead: input * read)
    }

    /// OpenAI's: cached input at its own price, and cache writes (GPT-6) at their 30-minute price.
    static func openAI(_ input: Double, _ cached: Double, _ output: Double, write: Double? = nil) -> ModelPrice {
        ModelPrice(input: input, output: output, cacheWrite5m: write ?? input, cacheWrite1h: write ?? input,
                   cacheRead: cached)
    }
}

/// An estimate of what the logged usage would cost through the API. It is not a bill:
/// plans are flat-priced, and this only says what the same tokens are worth.
///
/// Prices are checked by hand against platform.claude.com/docs/en/about-claude/pricing and
/// developers.openai.com/api/docs/pricing (`checked`). Each request is priced at the tier it
/// was logged with: fast mode, and long prompts on models that charge more for them.
public enum Pricing {
    public static let checked = "2026-10-22"
    /// Claude's web search, per search.
    public static let webSearch = 10.0 / 1000
    /// Prompts over this many tokens pay Claude Haiku 5.5's higher prices.
    static let haikuLongPrompt = 100_000
    /// And over this many, the long-context prices of OpenAI's newer models.
    static let openAILongPrompt = 272_000

    private struct Entry {
        var standard: ModelPrice
        var fast: ModelPrice?
        var long: ModelPrice?
    }

    /// Claude ids, matched by substring in this order (more specific first).
    private static let claude: [(String, Entry)] = [
        ("fable-5-1", Entry(standard: .claude(10, 50, read: 0.025))),
        ("mythos-5-1", Entry(standard: .claude(10, 50, read: 0.025))),
        ("fable-5", Entry(standard: .claude(10, 50))),
        ("mythos-5", Entry(standard: .claude(10, 50))),
        ("opus-5-5", Entry(standard: .claude(4, 20, read: 0.05), fast: .claude(8, 40, read: 0.05))),
        ("opus-5", Entry(standard: .claude(5, 25), fast: .claude(10, 50))),
        ("opus-4-8", Entry(standard: .claude(5, 25), fast: .claude(10, 50))),
        ("opus-4-7", Entry(standard: .claude(5, 25))),
        ("opus-4-6", Entry(standard: .claude(5, 25))),
        ("opus-4-5", Entry(standard: .claude(5, 25))),
        ("opus-4", Entry(standard: .claude(15, 75))),
        ("3-opus", Entry(standard: .claude(15, 75))),
        ("sonnet-5-5", Entry(standard: .claude(2, 10, read: 0.05))),
        ("sonnet-5", Entry(standard: .claude(2, 10))),
        ("sonnet-4", Entry(standard: .claude(3, 15))),
        ("3-7-sonnet", Entry(standard: .claude(3, 15))),
        ("3-5-sonnet", Entry(standard: .claude(3, 15))),
        ("haiku-5-5", Entry(standard: .claude(0.10, 0.50), long: .claude(0.50, 2.50))),
        ("haiku-4-5", Entry(standard: .claude(1, 5))),
        ("3-5-haiku", Entry(standard: .claude(0.80, 4))),
    ]

    /// OpenAI ids, matched exactly. Models the page does not list (codex-auto-review…) stay unpriced.
    private static let openAI: [String: Entry] = [
        "gpt-5.5": Entry(standard: .openAI(5, 0.50, 30), long: .openAI(10, 1, 45)),
        "gpt-5.5-pro": Entry(standard: .openAI(30, 30, 180), long: .openAI(60, 60, 270)),
        "gpt-5.4": Entry(standard: .openAI(2.50, 0.25, 15), long: .openAI(5, 0.50, 22.50)),
        "gpt-5.3-codex": Entry(standard: .openAI(1.75, 0.175, 14)),
        "gpt-5": Entry(standard: .openAI(1.25, 0.125, 10)),
        "gpt-5-mini": Entry(standard: .openAI(0.25, 0.025, 2)),
        "gpt-6-astra": Entry(standard: .openAI(10, 1, 50, write: 12.50), long: .openAI(20, 2, 75, write: 25)),
        "gpt-6.1-sol": Entry(standard: .openAI(2, 0.10, 10, write: 2.50), long: .openAI(4, 0.20, 15, write: 5)),
        "gpt-6-sol": Entry(standard: .openAI(2, 0.20, 10, write: 2.50), long: .openAI(4, 0.40, 15, write: 5)),
        "gpt-6-luna": Entry(standard: .openAI(0.10, 0.01, 0.50, write: 0.125), long: .openAI(0.20, 0.02, 0.75, write: 0.25)),
    ]

    private static func entry(_ model: String) -> Entry? {
        let id = canonical(model)
        if let entry = openAI[id] { return entry }
        guard id.contains("claude") else { return nil }
        return claude.first { id.contains($0.0) }?.1
    }

    public static func price(model: String, tier: String = "") -> ModelPrice? {
        guard let entry = entry(model) else { return nil }
        switch tier {
        case "fast": return entry.fast ?? entry.standard
        case "long": return entry.long ?? entry.standard
        default: return entry.standard
        }
    }

    /// The tier a request is priced at: "fast" in Claude's fast mode, "long" for a prompt
    /// over the model's threshold, "" otherwise.
    public static func tier(model: String, inputSide: Int, fast: Bool) -> String {
        guard let entry = entry(model) else { return "" }
        if fast, entry.fast != nil { return "fast" }
        if entry.long != nil {
            let threshold = canonical(model).hasPrefix("claude") ? haikuLongPrompt : openAILongPrompt
            if inputSide > threshold { return "long" }
        }
        return ""
    }

    /// In dollars, or nil when the model has no known price.
    public static func cost(_ counts: TokenCounts, model: String, tier: String = "") -> Double? {
        guard let price = price(model: model, tier: tier) else { return nil }
        let tokens = Double(counts.input) * price.input + Double(counts.output) * price.output
            + Double(counts.cacheWrite5m) * price.cacheWrite5m + Double(counts.cacheWrite1h) * price.cacheWrite1h
            + Double(counts.cacheRead) * price.cacheRead
        return tokens / 1_000_000 + Double(counts.webSearches) * webSearch
    }

    /// "us.anthropic.claude-opus-4-1-20250805-v1:0", "claude-opus-5-5[1m]" → "claude-opus-4-1", "claude-opus-5-5".
    public static func canonical(_ model: String) -> String {
        var id = model.lowercased().trimmingCharacters(in: .whitespaces)
        if let slash = id.lastIndex(of: "/") { id = String(id[id.index(after: slash)...]) }
        if let range = id.range(of: "claude-") { id = String(id[range.lowerBound...]) }
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        if let at = id.firstIndex(of: "@") { id = String(id[..<at]) }
        // A date stamp and whatever follows it ("-20250805-v1:0").
        if let range = id.range(of: #"-20\d{6}.*$"#, options: .regularExpression) { id.removeSubrange(range) }
        return id
    }
}

/// Readable model names for the stats ("Opus 5.5", "GPT-5.5").
public enum ModelNames {
    public static let claudeFamilies = ["fable", "mythos", "opus", "sonnet", "haiku"]

    /// "Opus", "Sonnet", "GPT"…, or nil for an unknown model.
    public static func family(_ model: String) -> String? {
        let id = Pricing.canonical(model)
        if let family = claudeFamilies.first(where: { id.contains($0) }) { return family.capitalized }
        if id.hasPrefix("gpt") { return "GPT" }
        if id.contains("codex") { return "Codex" }
        return nil
    }

    public static func display(_ model: String) -> String {
        let id = Pricing.canonical(model)
        if id.hasPrefix("claude-") {
            let parts = id.dropFirst("claude-".count).split(separator: "-").map(String.init)
            // New style "opus-5-5", old style "3-5-haiku".
            if let familyIndex = parts.firstIndex(where: { claudeFamilies.contains($0) }) {
                let numbers = (familyIndex == 0 ? parts.dropFirst() : parts.prefix(familyIndex))
                    .filter { $0.allSatisfy(\.isNumber) && $0.count <= 2 }
                let version = numbers.joined(separator: ".")
                return parts[familyIndex].capitalized + (version.isEmpty ? "" : " \(version)")
            }
            return id
        }
        if id.hasPrefix("gpt-") { return "GPT-" + id.dropFirst(4) }
        return model
    }
}
