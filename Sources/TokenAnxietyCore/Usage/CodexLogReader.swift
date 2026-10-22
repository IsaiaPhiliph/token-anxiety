import Foundation

/// Codex's session logs: `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`, moved to
/// `archived_sessions/` when archived. A file is one thread: `session_meta` names it (and
/// its parent, for a subagent), `turn_context` says the model and effort of each turn, and
/// `event_msg` / `token_count` reports each request's tokens (`last_token_usage`) with the
/// thread's running total, which only grows. A repeated event (same total) is not counted.
public enum CodexLogReader {
    /// What a file has said so far, kept between reads of a growing file.
    public struct FileState: Codable, Sendable, Equatable {
        public var session: String?
        public var parent: String?
        public var directory: String?
        public var model: String?
        public var effort: String?
        public var lastTotal = 0

        public init() {}
    }

    /// One request read from a `token_count` event.
    public struct Request: Sendable, Equatable {
        public var date: Date
        public var counts: TokenCounts
        /// Input including the cached part, which decides the long-context price.
        public var promptTokens: Int
        public var contextWindow: Int?
        public var dedupKey: UInt64
    }

    /// The five-hour and weekly windows as Codex last logged them.
    public struct RateLimits: Codable, Sendable, Equatable {
        public struct Window: Codable, Sendable, Equatable {
            public var usedPercent: Double
            public var windowMinutes: Double?
            public var resetsAt: Date?
        }

        public var observedAt: Date
        public var primary: Window?
        public var secondary: Window?
        public var planType: String?
    }

    public static func roots(codexHome: URL) -> [URL] {
        [codexHome.appendingPathComponent("sessions"), codexHome.appendingPathComponent("archived_sessions")]
    }

    public static func codexHome(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                 environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent(".codex")
    }

    static func isCandidate(_ line: UnsafeRawBufferPointer) -> Bool {
        LogLines.contains(line, "\"token_count\"") || LogLines.contains(line, "\"turn_context\"")
            || LogLines.contains(line, "\"session_meta\"")
    }

    /// Updates `state` with the line, and returns the request it reports, if it is a new one.
    public static func read(_ data: Data, state: inout FileState) -> Request? {
        guard let json = try? JSONValue.parse(data), let payload = json["payload"] else { return nil }
        switch json["type"]?.string {
        case "session_meta":
            state.session = payload["id"]?.string ?? payload["session_id"]?.string ?? state.session
            state.parent = payload["parent_thread_id"]?.string?.nilIfEmpty ?? state.parent
            state.directory = payload["cwd"]?.string ?? state.directory
            return nil
        case "turn_context":
            state.model = payload["model"]?.string?.nilIfEmpty ?? state.model
            state.effort = payload["effort"]?.string?.nilIfEmpty ?? state.effort
            state.directory = payload["cwd"]?.string?.nilIfEmpty ?? state.directory
            return nil
        case "event_msg":
            guard payload["type"]?.string == "token_count", let info = payload["info"], !info.isNull,
                  let last = info["last_token_usage"], let stamp = json["timestamp"]?.string,
                  let date = LogLines.date(stamp) else { return nil }
            let total = info["total_token_usage"]?["total_tokens"]?.int
            if let total {
                // The same total again is the same request logged twice.
                guard total != state.lastTotal else { return nil }
                state.lastTotal = total
            }
            let input = max(0, last["input_tokens"]?.int ?? 0)
            let cached = min(input, max(0, last["cached_input_tokens"]?.int ?? 0))
            let written = min(input - cached, max(0, last["cache_write_input_tokens"]?.int ?? 0))
            let output = max(0, last["output_tokens"]?.int ?? 0)
            let counts = TokenCounts(input: input - cached - written, output: output, cacheWrite5m: written,
                                     cacheRead: cached, reasoning: min(output, max(0, last["reasoning_output_tokens"]?.int ?? 0)),
                                     requests: 1)
            guard counts.total > 0 else { return nil }
            // A forked thread copies its parent's events: same time, same totals.
            let key = StableHash.of("codex", stamp, String(total ?? -1), String(last["total_tokens"]?.int ?? -1))
            return Request(date: date, counts: counts, promptTokens: input,
                           contextWindow: info["model_context_window"]?.int, dedupKey: key)
        default:
            return nil
        }
    }

    /// The `rate_limits` of a `token_count` line, if it has any.
    static func rateLimits(_ data: Data) -> RateLimits? {
        guard let json = try? JSONValue.parse(data), json["payload"]?["type"]?.string == "token_count",
              let limits = json["payload"]?["rate_limits"], !limits.isNull,
              let date = json["timestamp"]?.string.flatMap(LogLines.date) else { return nil }
        func window(_ value: JSONValue?) -> RateLimits.Window? {
            guard let value, let used = value["used_percent"]?.double else { return nil }
            return RateLimits.Window(usedPercent: used, windowMinutes: value["window_minutes"]?.double,
                                     resetsAt: DateParsing.date(value["resets_at"]))
        }
        let result = RateLimits(observedAt: date, primary: window(limits["primary"]), secondary: window(limits["secondary"]),
                                planType: limits["plan_type"]?.string)
        return result.primary == nil && result.secondary == nil ? nil : result
    }

    /// The newest windows found in the most recently written logs: what Codex saw last.
    public static func latestRateLimits(codexHome: URL, files: Int = 6, tailBytes: Int = 512 << 10) -> RateLimits? {
        let fm = FileManager.default
        var candidates: [(URL, Date)] = []
        for root in roots(codexHome: codexHome) {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { continue }
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                candidates.append((url, values?.contentModificationDate ?? .distantPast))
            }
        }
        var newest: RateLimits?
        for (url, _) in candidates.sorted(by: { $0.1 > $1.1 }).prefix(files) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
            guard let tail = try? handle.readToEnd() else { continue }
            for line in tail.split(separator: 0x0A).reversed() where line.range(of: Data("rate_limits".utf8)) != nil {
                if let limits = rateLimits(Data(line)) {
                    if limits.observedAt > newest?.observedAt ?? .distantPast { newest = limits }
                    break
                }
            }
        }
        return newest
    }
}
