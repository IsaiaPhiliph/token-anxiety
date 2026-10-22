import Foundation
import Testing
@testable import TokenAnxietyCore

/// A Claude Code `assistant` line with the fields the reader uses.
private func claudeLine(message: String, request: String?, time: String, output: Int, model: String = "claude-opus-5-5",
                        session: String = "s1", cwd: String = "/work/app", branch: String = "main",
                        sidechain: Bool = false, agent: String? = nil, speed: String = "standard",
                        write5m: Int = 0, write1h: Int = 0) -> String {
    var record: [String: Any] = [
        "type": "assistant", "timestamp": time, "sessionId": session, "cwd": cwd, "gitBranch": branch,
        "isSidechain": sidechain, "entrypoint": "cli", "effort": "high",
        "message": ["id": message, "model": model, "role": "assistant",
                    "content": [["type": "text", "text": "usage of the word usage"]],
                    "usage": ["input_tokens": 10, "output_tokens": output,
                              "cache_creation_input_tokens": write5m + write1h, "cache_read_input_tokens": 1000,
                              "cache_creation": ["ephemeral_5m_input_tokens": write5m, "ephemeral_1h_input_tokens": write1h],
                              "server_tool_use": ["web_search_requests": 0], "speed": speed]],
    ]
    if let request { record["requestId"] = request }
    if let agent { record["agentId"] = agent }
    return String(data: try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), encoding: .utf8)!
}

private func codexLine(_ type: String, _ payload: [String: Any], time: String = "2026-10-20T10:00:00.000Z") -> String {
    let record: [String: Any] = ["timestamp": time, "type": type, "payload": payload]
    return String(data: try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), encoding: .utf8)!
}

private func tokenCount(time: String, total: Int, input: Int, cached: Int, output: Int, reasoning: Int = 0) -> String {
    codexLine("event_msg", [
        "type": "token_count",
        "info": ["total_token_usage": ["total_tokens": total],
                 "last_token_usage": ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output,
                                      "reasoning_output_tokens": reasoning, "total_tokens": input + output],
                 "model_context_window": 258_400],
        "rate_limits": ["primary": ["used_percent": 12.5, "window_minutes": 300, "resets_at": 1_800_000_000],
                        "secondary": ["used_percent": 40.0, "window_minutes": 10_080, "resets_at": 1_800_500_000],
                        "plan_type": "plus"],
    ], time: time)
}

/// A scratch folder laid out like `~/.claude/projects` and `~/.codex`.
private final class Sandbox {
    let root: URL
    var claude: URL { root.appendingPathComponent("claude/projects") }
    var codex: URL { root.appendingPathComponent("codex") }
    var store: URL { root.appendingPathComponent("store") }

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ta-usage-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ path: String, _ lines: [String], in base: URL, newline: Bool = true) {
        let url = base.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = lines.joined(separator: "\n") + (newline ? "\n" : "")
        try! Data(text.utf8).write(to: url)
    }

    func append(_ path: String, _ lines: [String], in base: URL) {
        let handle = try! FileHandle(forWritingTo: base.appendingPathComponent(path))
        try! handle.seekToEnd()
        try! handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try! handle.close()
    }

    func indexer(persistent: Bool = true) -> LedgerIndexer {
        LedgerIndexer(directory: persistent ? store : nil, claudeRoots: [claude], codexHome: codex,
                      names: ProjectNames(home: "/nowhere", fileExists: { _ in false }, isDirectory: { _ in false }))
    }
}

private let now = LogLines.date("2026-10-21T12:00:00.000Z")!

@Suite struct ClaudeLogTests {
    @Test func readsTokensAndTheCacheSplit() throws {
        let line = claudeLine(message: "m1", request: "r1", time: "2026-10-20T10:00:00.500Z", output: 50, write5m: 200, write1h: 300)
        guard case .usage(let usage) = ClaudeLogReader.parse(Data(line.utf8)) else { Issue.record("no usage"); return }
        #expect(usage.counts == TokenCounts(input: 10, output: 50, cacheWrite5m: 200, cacheWrite1h: 300, cacheRead: 1000, requests: 1))
        #expect(usage.date == DateParsing.iso8601("2026-10-20T10:00:00.500Z"))
        #expect(usage.model == "claude-opus-5-5")
        #expect(usage.branch == "main")
        #expect(usage.effort == "high")
        #expect(usage.dedupKey != nil)
    }

    @Test func skipsSyntheticResponsesAndReadsTitles() {
        let synthetic = claudeLine(message: "m", request: "r", time: "2026-10-20T10:00:00.000Z", output: 0, model: "<synthetic>")
        #expect(ClaudeLogReader.parse(Data(synthetic.utf8)) == nil)
        let title = #"{"type":"custom-title","customTitle":"Fix the login","sessionId":"s1"}"#
        #expect(ClaudeLogReader.parse(Data(title.utf8)) == .title(session: "s1", title: "Fix the login", custom: true))
        // A number where a string was expected does not lose the line.
        let odd = claudeLine(message: "m2", request: nil, time: "2026-10-20T10:00:00.000Z", output: 1)
            .replacingOccurrences(of: #""entrypoint":"cli""#, with: #""entrypoint":"cli","requestId":42"#)
        guard case .usage(let usage) = ClaudeLogReader.parse(Data(odd.utf8)) else { Issue.record("lost"); return }
        #expect(usage.requestID == "42")
    }

    @Test func countsEachResponseOnceWithItsLargestOutput() async {
        let box = Sandbox()
        box.write("-work-app/s1.jsonl", [
            claudeLine(message: "m1", request: "r1", time: "2026-10-20T10:00:00.000Z", output: 5),   // thinking, partial
            claudeLine(message: "m1", request: "r1", time: "2026-10-20T10:00:01.000Z", output: 700), // text, final
            claudeLine(message: "m1", request: nil, time: "2026-10-20T10:00:01.000Z", output: 700),  // lost its requestId
            claudeLine(message: "m2", request: "r2", time: "2026-10-20T11:00:00.000Z", output: 100),
            #"{"type":"user","message":{"content":"tool output mentioning \"usage\" and \"assistant\""}}"#,
        ], in: box.claude)
        // A subagent, and a forked session that copied m2.
        box.write("-work-app/s1/subagents/agent-a1.jsonl", [
            claudeLine(message: "m3", request: "r3", time: "2026-10-20T10:30:00.000Z", output: 40, sidechain: true, agent: "a1"),
        ], in: box.claude)
        box.write("-work-app/s2.jsonl", [
            claudeLine(message: "m2", request: "r2", time: "2026-10-20T11:00:00.000Z", output: 100, session: "s2"),
            claudeLine(message: "m4", request: "r4", time: "2026-10-20T12:00:00.000Z", output: 1, session: "s2"),
        ], in: box.claude)

        let ledger = await box.indexer(persistent: false).update(now: now)
        let total = ledger.totals().counts
        #expect(total.requests == 4)
        #expect(total.output == 700 + 100 + 40 + 1)
        #expect(ledger.sessions.count == 2)
        let s1 = ledger.sessions["claude:s1"]
        #expect(s1?.agents == ["a1"])
        #expect(s1?.counts.requests == 3)
        #expect(s1?.branches["main"] == s1?.counts.total)
        #expect(s1?.entrypoint == "cli")
    }

    @Test func readsOnlyWhatWasAddedAndKeepsItAcrossLaunches() async {
        let box = Sandbox()
        box.write("-work-app/s1.jsonl", [
            claudeLine(message: "m1", request: "r1", time: "2026-10-21T10:00:00.000Z", output: 5),
            claudeLine(message: "m2", request: "r2", time: "2026-10-21T10:05:00.000Z", output: 50),
        ], in: box.claude, newline: false) // m2 is still being written
        let first = await box.indexer().update(now: now)
        #expect(first.totals().counts.requests == 1)

        // The rest arrives: m2's line ends, m1 is logged again with its final output.
        box.append("-work-app/s1.jsonl", [
            "",
            claudeLine(message: "m1", request: "r1", time: "2026-10-21T10:00:02.000Z", output: 900),
        ], in: box.claude)
        let indexer = box.indexer() // a new launch, from what was saved
        let second = await indexer.update(now: now)
        #expect(second.totals().counts.requests == 2)
        #expect(second.totals().counts.output == 900 + 50)
        // Nothing new: nothing changes.
        let third = await indexer.update(now: now)
        #expect(third == second)
    }

    @Test func aRewrittenFileIsNotCountedTwice() async {
        let box = Sandbox()
        let lines = [claudeLine(message: "m1", request: "r1", time: "2026-10-21T10:00:00.000Z", output: 10),
                     claudeLine(message: "m2", request: "r2", time: "2026-10-21T10:01:00.000Z", output: 20)]
        box.write("-work-app/s1.jsonl", lines, in: box.claude)
        let indexer = box.indexer()
        _ = await indexer.update(now: now)
        // Replaced with a shorter file that keeps one old line and adds a new one.
        try? FileManager.default.removeItem(at: box.claude.appendingPathComponent("-work-app/s1.jsonl"))
        box.write("-work-app/s1.jsonl", [lines[0], claudeLine(message: "m3", request: "r3", time: "2026-10-21T10:02:00.000Z", output: 30)], in: box.claude)
        let ledger = await indexer.update(now: now)
        #expect(ledger.totals().counts.requests == 3)
        #expect(ledger.totals().counts.output == 60)
    }

    @Test func historyOutlivesTheLogs() async {
        let box = Sandbox()
        box.write("-work-app/s1.jsonl", [claudeLine(message: "m1", request: "r1", time: "2026-09-01T10:00:00.000Z", output: 10)],
                  in: box.claude)
        _ = await box.indexer().update(now: now)
        // Claude Code's cleanup deletes the transcript.
        try? FileManager.default.removeItem(at: box.claude)
        let ledger = await box.indexer().update(now: now)
        #expect(ledger.totals().counts.output == 10)
    }
}

@Suite struct CodexLogTests {
    private func session(id: String, parent: String? = nil, events: [String]) -> [String] {
        var meta: [String: Any] = ["id": id, "cwd": "/work/shop"]
        if let parent { meta["parent_thread_id"] = parent }
        return [codexLine("session_meta", meta),
                codexLine("turn_context", ["model": "gpt-5.5", "effort": "xhigh", "cwd": "/work/shop"])] + events
    }

    @Test func countsRequestsOnceEvenWhenArchivedOrForked() async {
        let box = Sandbox()
        let name = "rollout-2026-10-20T10-00-00-019e690e-ec27-7d30-8702-a4cd20523912.jsonl"
        box.write("sessions/2026/10/20/\(name)", session(id: "t1", events: [
            tokenCount(time: "2026-10-20T10:01:00.000Z", total: 1500, input: 1000, cached: 800, output: 500, reasoning: 200),
            tokenCount(time: "2026-10-20T10:01:01.000Z", total: 1500, input: 1000, cached: 800, output: 500), // logged twice
            tokenCount(time: "2026-10-20T10:02:00.000Z", total: 4000, input: 2000, cached: 1500, output: 500),
        ]), in: box.codex)
        let indexer = box.indexer()
        let first = await indexer.update(now: now)
        let counts = first.totals(provider: .codex).counts
        #expect(counts == TokenCounts(input: 700, output: 1000, cacheRead: 2300, reasoning: 200, requests: 2))
        #expect(first.sessions["codex:t1"]?.efforts == ["xhigh": 2])

        // Archived: the same file somewhere else. A subagent copies its parent's first event.
        try? FileManager.default.createDirectory(at: box.codex.appendingPathComponent("archived_sessions"), withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: box.codex.appendingPathComponent("sessions/2026/10/20/\(name)"),
                                          to: box.codex.appendingPathComponent("archived_sessions/\(name)"))
        box.write("sessions/2026/10/20/rollout-2026-10-20T10-05-00-019e690e-0000-7d30-8702-a4cd20523999.jsonl", session(id: "t2", parent: "t1", events: [
            tokenCount(time: "2026-10-20T10:01:00.000Z", total: 1500, input: 1000, cached: 800, output: 500, reasoning: 200),
            tokenCount(time: "2026-10-20T10:06:00.000Z", total: 1800, input: 300, cached: 0, output: 0),
        ]), in: box.codex)
        let second = await indexer.update(now: now)
        #expect(second.totals(provider: .codex).counts.requests == 3)
        #expect(second.sessions["codex:t1"]?.agents == ["t2"])
        #expect(second.sessions.count == 1)
    }

    @Test func latestLimitsStandInForTheServer() throws {
        let box = Sandbox()
        box.write("sessions/2026/10/20/rollout-a.jsonl", session(id: "t1", events: [
            tokenCount(time: "2026-10-20T10:01:00.000Z", total: 10, input: 5, cached: 0, output: 5),
        ]), in: box.codex)
        let limits = try #require(CodexLogReader.latestRateLimits(codexHome: box.codex))
        #expect(limits.primary?.usedPercent == 12.5)
        #expect(limits.secondary?.windowMinutes == 10_080)
        #expect(limits.planType == "plus")

        // Before the five-hour reset it shows as logged; after it, empty.
        let before = CodexProvider.snapshot(logLimits: limits, now: Date(timeIntervalSince1970: 1_799_999_000))
        #expect(before.primary?.usedPercent == 12.5)
        #expect(before.secondary?.usedPercent == 40)
        let after = CodexProvider.snapshot(logLimits: limits, now: Date(timeIntervalSince1970: 1_800_100_000))
        #expect(after.primary?.usedPercent == 0)
        #expect(after.primary?.resetsAt == nil)
        #expect(after.secondary?.usedPercent == 40)
        #expect(after.fetchedAt == limits.observedAt)
    }

    @Test func fileNamesGiveTheThread() {
        #expect(LedgerIndexer.codexSession(fromFileName: "rollout-2026-05-27T12-50-46-019e690e-ec27-7d30-8702-a4cd20523912.jsonl")
                == "019e690e-ec27-7d30-8702-a4cd20523912")
    }
}

@Suite struct PricingTests {
    @Test func pricesEachKindOfToken() throws {
        let counts = TokenCounts(input: 1_000_000, output: 1_000_000, cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000,
                                 cacheRead: 1_000_000, requests: 1, webSearches: 2)
        // Opus 5.5: $4 in, $20 out, $5 / $8 writes, $0.20 reads, $0.01 per search.
        #expect(abs(try #require(Pricing.cost(counts, model: "claude-opus-5-5")) - 37.22) < 1e-9)
        // Fast mode doubles it, cache multipliers on top.
        #expect(abs(try #require(Pricing.cost(counts, model: "claude-opus-5-5", tier: "fast")) - 74.42) < 1e-9)
        // Sonnet 5.5 reads at 0.05x, Fable 5.1 at 0.025x.
        #expect(Pricing.price(model: "claude-sonnet-5-5")?.cacheRead == 0.10)
        #expect(Pricing.price(model: "claude-fable-5-1")?.cacheRead == 0.25)
        #expect(Pricing.price(model: "claude-opus-4-1-20250805")?.output == 75)
        #expect(Pricing.price(model: "us.anthropic.claude-sonnet-4-5-20250929-v1:0")?.input == 3)
        #expect(Pricing.price(model: "claude-3-5-haiku-20241022")?.input == 0.80)
        #expect(Pricing.cost(counts, model: "codex-auto-review") == nil)
    }

    @Test func choosesTheTier() {
        #expect(Pricing.tier(model: "claude-haiku-5-5", inputSide: 150_000, fast: false) == "long")
        #expect(Pricing.tier(model: "claude-haiku-5-5", inputSide: 90_000, fast: false) == "")
        #expect(Pricing.tier(model: "claude-opus-5-5", inputSide: 900_000, fast: false) == "")
        #expect(Pricing.tier(model: "claude-opus-5-5", inputSide: 10, fast: true) == "fast")
        #expect(Pricing.tier(model: "claude-sonnet-5-5", inputSide: 10, fast: true) == "")
        #expect(Pricing.tier(model: "gpt-5.5", inputSide: 300_000, fast: false) == "long")
        #expect(Pricing.price(model: "gpt-5.5", tier: "long")?.output == 45)
    }

    @Test func namesModels() {
        #expect(ModelNames.display("claude-opus-5-5") == "Opus 5.5")
        #expect(ModelNames.display("claude-sonnet-4-20250514") == "Sonnet 4")
        #expect(ModelNames.display("claude-3-5-haiku-20241022") == "Haiku 3.5")
        #expect(ModelNames.display("claude-opus-5-5[1m]") == "Opus 5.5")
        #expect(ModelNames.display("gpt-5.5") == "GPT-5.5")
        #expect(ModelNames.family("claude-haiku-5-5") == "Haiku")
    }
}

@Suite struct UsageSupportTests {
    @Test func namesProjectsAfterTheirRepository() {
        let files: [String: String] = ["/work/app/.claude/worktrees/fix/.git": "gitdir: /work/app/.git/worktrees/fix\n"]
        let names = ProjectNames(home: "/Users/me", fileExists: { files[$0] != nil || $0 == "/work/app/.git" },
                                 isDirectory: { $0 == "/work/app/.git" }, readFile: { files[$0] })
        #expect(names.name(for: "/work/app/Sources/Core") == "app")
        #expect(names.name(for: "/work/app/.claude/worktrees/fix/Sources") == "app")
        #expect(names.name(for: "/gone/shop/.claude/worktrees/old-branch") == "shop")
        #expect(names.name(for: "/Users/me/.codex/worktrees/ab12/shop/web") == "shop")
        #expect(names.name(for: "/Users/me") == "~")
        #expect(names.name(for: nil) == ProjectNames.unknown)
    }

    @Test func parsesLogTimestampsQuickly() {
        for text in ["2026-10-22T14:05:31.123Z", "2026-01-01T00:00:00Z", "2024-02-29T23:59:59.999Z"] {
            let fast = LogLines.date(text)?.timeIntervalSince1970 ?? 0
            let slow = DateParsing.iso8601(text)?.timeIntervalSince1970 ?? 1
            #expect(abs(fast - slow) < 1e-6)
        }
        #expect(LogLines.date("2026-10-22T14:05:31+02:00") == DateParsing.iso8601("2026-10-22T14:05:31+02:00"))
    }

    @Test func keysSurviveTheRoundTrip() {
        let keys: Set<UInt64> = [0, 1, .max, StableHash.of("claude", "m1", "r1")]
        #expect(Set(LedgerIndexer.keys(from: LedgerIndexer.keyData(keys))) == keys)
        #expect(StableHash.of("a", "bc") != StableHash.of("ab", "c"))
    }

    @Test func groupsByLocalDay() {
        var ledger = UsageLedger()
        let event = { (time: String) in
            UsageEvent(provider: .claude, date: LogLines.date(time)!, session: "s", project: "p", model: "claude-opus-5-5",
                       counts: TokenCounts(output: 1, requests: 1))
        }
        ledger.add(event("2026-10-20T21:30:00.000Z")) // 23:30 in Madrid
        ledger.add(event("2026-10-20T22:30:00.000Z")) // 00:30 the next day
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        let days = ledger.daily(calendar: calendar)
        #expect(days.count == 2)
        #expect(days.values.allSatisfy { $0.counts.requests == 1 })
    }

    @Test func readsRetryAfter() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(HTTP.retryAfter("120") == 120)
        #expect(HTTP.retryAfter("Fri, 15 Jan 2027 08:02:00 GMT", now: now) == 120) // 1_800_000_000 is 08:00 that day
        #expect(HTTP.retryAfter("soon") == nil)
        #expect(HTTP.retryAfter(nil) == nil)
    }
}
