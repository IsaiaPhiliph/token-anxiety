import Foundation

/// How big each kind of content in Claude Code's conversations was: your prompts, what
/// tools sent back (per tool), Claude's replies and tool calls. Only sizes are kept, never
/// text. Tokens are estimated from them (about four characters a token), since the logs
/// count tokens per request, not per piece.
public struct ContentCounts: Codable, Sendable, Equatable {
    /// Characters of each kind.
    public var prompts = 0
    /// Instructions Claude wrote for its subagents.
    public var agentPrompts = 0
    public var replies = 0
    public var toolCalls = 0
    public var thinking = 0
    public var toolResults: [String: Int] = [:]
    public var images = 0

    public init() {}

    /// About four characters per token; an image counts as some 1,600 tokens.
    public static let charactersPerToken = 4.0
    public static let tokensPerImage = 1600.0

    public static func tokens(_ characters: Int) -> Double { Double(characters) / charactersPerToken }

    public var toolResultCharacters: Int { toolResults.values.reduce(0, +) }

    public static func += (lhs: inout ContentCounts, rhs: ContentCounts) {
        lhs.prompts += rhs.prompts
        lhs.agentPrompts += rhs.agentPrompts
        lhs.replies += rhs.replies
        lhs.toolCalls += rhs.toolCalls
        lhs.thinking += rhs.thinking
        lhs.images += rhs.images
        for (tool, characters) in rhs.toolResults { lhs.toolResults[tool, default: 0] += characters }
    }

    enum CodingKeys: String, CodingKey {
        case prompts = "p", agentPrompts = "a", replies = "r", toolCalls = "c", thinking = "t", toolResults = "tr", images = "i"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prompts = try c.decodeIfPresent(Int.self, forKey: .prompts) ?? 0
        agentPrompts = try c.decodeIfPresent(Int.self, forKey: .agentPrompts) ?? 0
        replies = try c.decodeIfPresent(Int.self, forKey: .replies) ?? 0
        toolCalls = try c.decodeIfPresent(Int.self, forKey: .toolCalls) ?? 0
        thinking = try c.decodeIfPresent(Int.self, forKey: .thinking) ?? 0
        toolResults = try c.decodeIfPresent([String: Int].self, forKey: .toolResults) ?? [:]
        images = try c.decodeIfPresent(Int.self, forKey: .images) ?? 0
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        for (key, value) in [(CodingKeys.prompts, prompts), (.agentPrompts, agentPrompts), (.replies, replies),
                             (.toolCalls, toolCalls), (.thinking, thinking), (.images, images)] where value != 0 {
            try c.encode(value, forKey: key)
        }
        if !toolResults.isEmpty { try c.encode(toolResults, forKey: .toolResults) }
    }
}

/// Measures one transcript line for `ContentCounts`.
public enum ContentReader {
    public struct Line: Sendable, Equatable {
        public var uuid: String?
        public var date: Date
        public var counts: ContentCounts
        /// Tool calls made in this line, to name their results later: id → tool.
        public var toolCalls: [String: String]
        /// Results in this line, by the id of the call they answer: id → characters.
        public var results: [String: Int]
    }

    static func isCandidate(_ line: UnsafeRawBufferPointer) -> Bool {
        LogLines.contains(line, "\"user\"") || LogLines.contains(line, "\"assistant\"")
    }

    public static func read(_ data: Data) -> Line? {
        guard let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = record["type"] as? String, type == "user" || type == "assistant",
              let stamp = record["timestamp"] as? String, let date = LogLines.date(stamp),
              let message = record["message"] as? [String: Any] else { return nil }
        // Claude Code's own notes (`isMeta`) and made-up replies are not conversation.
        if record["isMeta"] as? Bool == true || message["model"] as? String == "<synthetic>" { return nil }
        let sidechain = record["isSidechain"] as? Bool == true
        var counts = ContentCounts()
        var calls: [String: String] = [:]
        var results: [String: Int] = [:]

        func addText(_ length: Int) {
            if type == "assistant" {
                counts.replies += length
            } else if sidechain {
                counts.agentPrompts += length
            } else {
                counts.prompts += length
            }
        }

        if let text = message["content"] as? String {
            addText(text.utf16.count)
        } else if let blocks = message["content"] as? [[String: Any]] {
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    addText((block["text"] as? String)?.utf16.count ?? 0)
                case "thinking":
                    counts.thinking += (block["thinking"] as? String)?.utf16.count ?? 0
                case "tool_use":
                    let input = block["input"].flatMap { try? JSONSerialization.data(withJSONObject: $0) }?.count ?? 0
                    counts.toolCalls += input
                    if let id = block["id"] as? String, let name = block["name"] as? String { calls[id] = name }
                case "tool_result":
                    let (characters, images) = size(of: block["content"])
                    counts.images += images
                    if let id = block["tool_use_id"] as? String { results[id, default: 0] += characters }
                case "image":
                    counts.images += 1
                default:
                    break
                }
            }
        } else {
            return nil
        }
        return Line(uuid: record["uuid"] as? String, date: date, counts: counts, toolCalls: calls, results: results)
    }

    /// A tool result's content: a string, or blocks of text and images.
    private static func size(of content: Any?) -> (characters: Int, images: Int) {
        if let text = content as? String { return (text.utf16.count, 0) }
        guard let blocks = content as? [[String: Any]] else { return (0, 0) }
        var characters = 0
        var images = 0
        for block in blocks {
            if let text = block["text"] as? String { characters += text.utf16.count }
            if block["type"] as? String == "image" { images += 1 }
        }
        return (characters, images)
    }

    /// The short name a tool's results are filed under: "Read", "Bash", "mcp__github__get_issue" → "github".
    public static func toolName(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "Other" }
        if raw.hasPrefix("mcp__") {
            let parts = raw.split(separator: "_", omittingEmptySubsequences: true)
            return parts.count >= 2 ? "MCP · \(parts[1])" : "MCP"
        }
        return raw
    }
}
