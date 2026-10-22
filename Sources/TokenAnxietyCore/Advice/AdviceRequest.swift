import Foundation

/// AI advice on how to make a plan last: the last 30 days, as aggregates only, go to the
/// Anthropic API with the user's own key, and tips come back as structured JSON.
///
/// Nothing is sent without the user seeing the exact request first (`body`), and the
/// request never carries prompts, paths, accounts or (unless asked) project names.
public enum Advice {
    public static let model = "claude-opus-5-5"
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// Lets a refused request run again on Anthropic's recommended fallback model.
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    public struct Tip: Codable, Sendable, Equatable, Identifiable {
        public var title: String
        public var evidence: String
        public var action: String
        /// The user's verdict: true helpful, false not.
        public var helpful: Bool?

        public var id: String { title }

        public init(title: String, evidence: String, action: String, helpful: Bool? = nil) {
            self.title = title
            self.evidence = evidence
            self.action = action
            self.helpful = helpful
        }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case refused
        case truncated
        case unreadable
        case api(status: Int, message: String)
        /// A plan's command-line tool failed, with what it said.
        case tool(String)

        public var errorDescription: String? {
            switch self {
            case .refused: String(localized: "Claude declined to answer this request.")
            case .truncated: String(localized: "The answer was cut short. Try again.")
            case .unreadable: String(localized: "The answer could not be read.")
            case .api(let status, let message): String(localized: "The API answered \(status): \(message)")
            case .tool(let message): message
            }
        }
    }

    // MARK: The request

    /// The 30 days before `now`, summed up: tokens, cost, models, effort, hours, content,
    /// sessions and limits.
    public static func summary(ledger: UsageLedger, now: Date = Date(), calendar: Calendar = .current,
                               includeProjects: Bool = false, plans: [ProviderID: String] = [:],
                               weeklyUsed: [ProviderID: Double] = [:]) -> [String: Any] {
        let start = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        let interval = DateInterval(start: start, end: now)
        let totals = ledger.totals(in: interval)
        let counts = totals.counts
        func round(_ value: Double, _ places: Double = 100) -> Double { (value * places).rounded() / places }

        var summary: [String: Any] = [
            "period_days": 30,
            "totals": [
                "tokens": counts.total, "input_uncached": counts.input, "output": counts.output,
                "cache_write": counts.cacheWrite, "cache_read": counts.cacheRead, "requests": counts.requests,
                "web_searches": counts.webSearches, "api_equivalent_cost_usd": round(totals.cost),
            ] as [String: Any],
            "cache_hit_rate_of_input": round(counts.cacheHitRate ?? 0, 1000),
            "active_days": ledger.daily(in: interval, calendar: calendar).values.filter { $0.counts.requests > 0 }.count,
        ]
        summary["by_service"] = Dictionary(uniqueKeysWithValues: [ProviderID.claude, .codex].compactMap { provider in
            let t = ledger.totals(in: interval, provider: provider)
            return t.counts.requests > 0 ? (provider.rawValue, ["tokens": t.counts.total, "requests": t.counts.requests,
                                                                 "api_equivalent_cost_usd": round(t.cost)] as [String: Any]) : nil
        })
        summary["by_model"] = ledger.grouped(in: interval) { ModelNames.display($0.model) }
            .sorted { $0.value.counts.total > $1.value.counts.total }
            .map { ["model": $0.key, "tokens": $0.value.counts.total, "output": $0.value.counts.output,
                    "requests": $0.value.counts.requests, "api_equivalent_cost_usd": round($0.value.cost)] as [String: Any] }
        summary["requests_by_effort"] = ledger.grouped(in: interval) { $0.effort }
            .filter { !$0.key.isEmpty }.mapValues(\.counts.requests)
        let hours = ledger.byHourOfDay(in: interval, calendar: calendar)
        let hourTotal = max(1, hours.values.reduce(0) { $0 + $1.counts.total })
        summary["share_of_tokens_by_local_hours"] = Dictionary(uniqueKeysWithValues: stride(from: 0, to: 24, by: 6).map { from in
            ("\(from)-\(from + 6)", round(Double((from..<from + 6).reduce(0) { $0 + (hours[$1]?.counts.total ?? 0) }) / Double(hourTotal)))
        })

        let content = ledger.content(in: interval)
        if content.prompts + content.toolResultCharacters + content.replies > 0 {
            summary["claude_code_content_estimated_tokens"] = [
                "your_prompts": Int(ContentCounts.tokens(content.prompts)),
                "subagent_instructions": Int(ContentCounts.tokens(content.agentPrompts)),
                "claude_replies": Int(ContentCounts.tokens(content.replies)),
                "tool_calls": Int(ContentCounts.tokens(content.toolCalls)),
                "tool_results_by_tool": content.toolResults.sorted { $0.value > $1.value }.prefix(12)
                    .reduce(into: [String: Int]()) { $0[$1.key] = Int(ContentCounts.tokens($1.value)) },
            ] as [String: Any]
        }

        let sessions = ledger.sessions(in: interval)
        if !sessions.isEmpty {
            let minutes = sessions.map { $0.duration / 60 }.sorted()
            let requests = sessions.map { $0.counts.requests }.sorted()
            summary["sessions"] = [
                "count": sessions.count,
                "median_minutes": Int(minutes[minutes.count / 2]),
                "median_requests": requests[requests.count / 2],
                "with_subagents": sessions.filter { !$0.agents.isEmpty }.count,
                "largest_context_tokens": sessions.map(\.peakContext).max() ?? 0,
                "median_peak_context_tokens": sessions.map(\.peakContext).sorted()[sessions.count / 2],
            ] as [String: Any]
        }
        if !plans.isEmpty { summary["plans"] = Dictionary(uniqueKeysWithValues: plans.map { ($0.key.rawValue, $0.value) }) }
        if !weeklyUsed.isEmpty {
            summary["weekly_limit_used_percent_now"] = Dictionary(uniqueKeysWithValues: weeklyUsed.map { ($0.key.rawValue, round($0.value, 1)) })
        }
        if includeProjects {
            summary["top_projects"] = ledger.grouped(in: interval, by: \.project)
                .sorted { $0.value.counts.total > $1.value.counts.total }.prefix(8)
                .map { ["project": $0.key, "tokens": $0.value.counts.total] as [String: Any] }
        }
        return summary
    }

    /// The answer's shape: a list of tips, each with its evidence and one action.
    public static var schema: [String: Any] {
        let tip: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["title", "evidence", "action"],
            "properties": ["title": ["type": "string"], "evidence": ["type": "string"], "action": ["type": "string"]],
        ]
        return [
            "type": "object", "additionalProperties": false, "required": ["tips"],
            "properties": ["tips": ["type": "array", "items": tip]],
        ]
    }

    public static func instructions(language: String) -> String {
        """
        You coach someone who uses Claude Code and Codex on flat-rate plans with five-hour and weekly limits. \
        From the usage aggregates you are given, and nothing else, give three to six concrete tips that would make \
        their limits last longer or waste fewer tokens: cache behaviour, model and effort choice, the size of tool \
        output, session length and context size, when they work. Every tip cites numbers from the data as evidence \
        and ends in one specific action. Leave out any tip the data does not support. Write in \(language).
        """
    }

    /// The aggregates as the message the model reads.
    public static func message(summary: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]))
            ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The whole Messages API request body, exactly as it will be sent.
    public static func body(summary: [String: Any], language: String) -> Data {
        let request: [String: Any] = [
            "model": model,
            "max_tokens": 16_000,
            "fallbacks": "default",
            "output_config": ["effort": "medium", "format": ["type": "json_schema", "schema": schema]],
            "system": instructions(language: language),
            "messages": [["role": "user", "content": message(summary: summary)]],
        ]
        return (try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]))
            ?? Data()
    }

    public static func request(body: Data, apiKey: String, endpoint: URL = endpoint) -> URLRequest {
        var request = HTTP.request(endpoint, method: "POST", headers: [
            "Content-Type": "application/json",
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
            "anthropic-beta": fallbackBeta,
        ], body: body, timeout: 180)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: The answer

    public static func send(body: Data, apiKey: String, endpoint: URL = endpoint,
                            session: URLSession = .shared) async throws -> [Tip] {
        let (data, status) = try await HTTP.send(request(body: body, apiKey: apiKey, endpoint: endpoint), session: session)
        guard (200..<300).contains(status) else {
            let message = (try? JSONValue.parse(data))?["error"]?["message"]?.string ?? String(localized: "no details")
            throw Failure.api(status: status, message: message)
        }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> [Tip] {
        guard let json = try? JSONValue.parse(data) else { throw Failure.unreadable }
        switch json["stop_reason"]?.string {
        case "refusal": throw Failure.refused
        case "max_tokens": throw Failure.truncated
        default: break
        }
        let text = (json["content"]?.array ?? []).first { $0["type"]?.string == "text" }?["text"]?.string
        return try tips(fromJSONText: text)
    }

    /// `{"tips": [...]}`, as the model wrote it (some wrap it in a code fence).
    static func tips(fromJSONText text: String?) throws -> [Tip] {
        guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { throw Failure.unreadable }
        if text.hasPrefix("```"), let start = text.firstIndex(of: "\n"), let end = text.range(of: "```", options: .backwards),
           end.lowerBound > start {
            text = String(text[text.index(after: start)..<end.lowerBound])
        }
        guard let tips = try? JSONDecoder().decode([String: [Tip]].self, from: Data(text.utf8))["tips"] else {
            throw Failure.unreadable
        }
        return tips
    }
}
