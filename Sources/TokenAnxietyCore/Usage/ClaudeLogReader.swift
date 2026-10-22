import Foundation

/// Claude Code's transcripts: `<config dir>/projects/<folder>/<session>.jsonl`, plus
/// `<session>/subagents/agent-*.jsonl` for its subagents. Every model response is an
/// `assistant` line with a `usage` object; nothing else is read from it (never the text).
///
/// One response is often written several times: once per content block (thinking, text,
/// tool use) and again as its output grows, and a forked or resumed session copies old
/// lines into a new file. They share `message.id` + `requestId`, which the indexer uses
/// to count each response once, keeping its largest token counts.
public enum ClaudeLogReader {
    public enum Line: Sendable, Equatable {
        case usage(Usage)
        /// A session's name: one the user set (`custom-title`) or Claude Code's own (`agent-name`).
        case title(session: String, title: String, custom: Bool)
    }

    public struct Usage: Sendable, Equatable {
        public var messageID: String?
        public var requestID: String?
        public var date: Date
        public var session: String?
        public var directory: String?
        public var branch: String?
        public var model: String
        public var effort: String?
        public var agent: String?
        public var entrypoint: String?
        public var fast: Bool
        public var counts: TokenCounts

        /// The key that identifies one response across its repeated lines.
        public var dedupKey: UInt64? {
            guard messageID != nil || requestID != nil else { return nil }
            return StableHash.of("claude", messageID ?? "", requestID ?? "")
        }
    }

    /// The `projects` folders to read: `CLAUDE_CONFIG_DIR` (a comma-separated list is
    /// allowed) and `~/.claude`.
    public static func roots(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                             environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var roots: [URL] = []
        for entry in (environment["CLAUDE_CONFIG_DIR"] ?? "").split(separator: ",") {
            let path = (entry.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            if !path.isEmpty { roots.append(URL(fileURLWithPath: path).appendingPathComponent("projects")) }
        }
        roots.append(home.appendingPathComponent(".claude/projects"))
        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Cheap byte checks first: most of a transcript is prompts and tool output.
    static func isCandidate(_ line: UnsafeRawBufferPointer) -> Bool {
        (LogLines.contains(line, "\"usage\"") && LogLines.contains(line, "\"assistant\""))
            || LogLines.contains(line, "\"custom-title\"") || LogLines.contains(line, "\"agent-name\"")
    }

    public static func parse(_ data: Data) -> Line? {
        guard let record = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
        switch record.type {
        case "custom-title":
            guard let session = record.sessionId, let title = record.customTitle?.trimmed, !title.isEmpty else { return nil }
            return .title(session: session, title: title, custom: true)
        case "agent-name":
            guard let session = record.sessionId, let title = record.agentName?.trimmed, !title.isEmpty else { return nil }
            return .title(session: session, title: title, custom: false)
        case "assistant":
            guard let message = record.message, let usage = message.usage,
                  let stamp = record.timestamp, let date = LogLines.date(stamp) else { return nil }
            let model = message.model?.trimmed ?? ""
            // Claude Code's own placeholder for responses it made up (errors, interruptions).
            guard !model.isEmpty, model != "<synthetic>" else { return nil }
            let created = usage.cacheCreation ?? 0
            var write1h = usage.ephemeral1h ?? 0
            var write5m = usage.ephemeral5m ?? 0
            if write5m + write1h > created { write1h = min(write1h, created); write5m = created - write1h }
            // Writes without a TTL split are Claude Code's default, five minutes.
            write5m += max(0, created - write5m - write1h)
            let counts = TokenCounts(input: max(0, usage.input ?? 0), output: max(0, usage.output ?? 0),
                                     cacheWrite5m: max(0, write5m), cacheWrite1h: max(0, write1h),
                                     cacheRead: max(0, usage.cacheRead ?? 0), requests: 1,
                                     webSearches: max(0, usage.webSearches ?? 0))
            return .usage(Usage(messageID: message.id, requestID: record.requestId, date: date,
                                session: record.sessionId, directory: record.cwd,
                                branch: record.gitBranch?.trimmed.nilIfEmpty, model: model,
                                effort: record.effort?.trimmed.nilIfEmpty,
                                agent: record.isSidechain == true ? (record.agentId ?? "sidechain") : nil,
                                entrypoint: record.entrypoint, fast: usage.speed == "fast", counts: counts))
        default:
            return nil
        }
    }

    // MARK: The fields read

    private struct Record: Decodable {
        var type: String?
        var timestamp: String?
        var sessionId: String?
        var cwd: String?
        var gitBranch: String?
        var isSidechain: Bool?
        var agentId: String?
        var requestId: String?
        var effort: String?
        var entrypoint: String?
        var customTitle: String?
        var agentName: String?
        var message: Message?

        enum CodingKeys: String, CodingKey {
            case type, timestamp, sessionId, cwd, gitBranch, isSidechain, agentId, requestId, effort
            case entrypoint, customTitle, agentName, message
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = c.lenient(String.self, .type)
            timestamp = c.lenient(String.self, .timestamp)
            sessionId = c.lenient(String.self, .sessionId)
            cwd = c.lenient(String.self, .cwd)
            gitBranch = c.lenient(String.self, .gitBranch)
            isSidechain = c.lenient(Bool.self, .isSidechain)
            agentId = c.lenient(String.self, .agentId)
            requestId = c.lenient(String.self, .requestId) ?? c.lenientInt(.requestId).map(String.init)
            effort = c.lenient(String.self, .effort)
            entrypoint = c.lenient(String.self, .entrypoint)
            customTitle = c.lenient(String.self, .customTitle)
            agentName = c.lenient(String.self, .agentName)
            message = c.lenient(Message.self, .message)
        }
    }

    private struct Message: Decodable {
        var id: String?
        var model: String?
        var usage: Usage?

        enum CodingKeys: String, CodingKey { case id, model, usage }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.lenient(String.self, .id)
            model = c.lenient(String.self, .model)
            usage = c.lenient(Usage.self, .usage)
        }

        struct Usage: Decodable {
            var input: Int?
            var output: Int?
            var cacheCreation: Int?
            var cacheRead: Int?
            var ephemeral5m: Int?
            var ephemeral1h: Int?
            var webSearches: Int?
            var speed: String?

            enum CodingKeys: String, CodingKey {
                case input = "input_tokens", output = "output_tokens"
                case cacheCreation = "cache_creation_input_tokens", cacheRead = "cache_read_input_tokens"
                case split = "cache_creation", server = "server_tool_use", speed
            }

            enum SplitKeys: String, CodingKey {
                case ephemeral5m = "ephemeral_5m_input_tokens", ephemeral1h = "ephemeral_1h_input_tokens"
            }

            enum ServerKeys: String, CodingKey { case webSearches = "web_search_requests" }

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                input = c.lenientInt(.input)
                output = c.lenientInt(.output)
                cacheCreation = c.lenientInt(.cacheCreation)
                cacheRead = c.lenientInt(.cacheRead)
                speed = c.lenient(String.self, .speed)
                if let split = try? c.nestedContainer(keyedBy: SplitKeys.self, forKey: .split) {
                    ephemeral5m = split.lenientInt(.ephemeral5m)
                    ephemeral1h = split.lenientInt(.ephemeral1h)
                }
                if let server = try? c.nestedContainer(keyedBy: ServerKeys.self, forKey: .server) {
                    webSearches = server.lenientInt(.webSearches)
                }
            }
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
