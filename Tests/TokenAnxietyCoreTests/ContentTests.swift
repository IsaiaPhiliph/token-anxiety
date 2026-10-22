import Foundation
import Testing
@testable import TokenAnxietyCore

@Suite struct ContentTests {
    private func line(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    @Test func measuresEachKindOfContent() throws {
        let prompt = line(["type": "user", "uuid": "u1", "timestamp": "2026-10-20T10:00:00.000Z",
                           "message": ["role": "user", "content": "Fix the tests"]])
        let call = line(["type": "assistant", "uuid": "u2", "timestamp": "2026-10-20T10:00:05.000Z",
                         "message": ["role": "assistant", "model": "claude-opus-5-5", "content": [
                            ["type": "text", "text": "Reading it."],
                            ["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "/a/b.swift"]],
                         ]]])
        let result = line(["type": "user", "uuid": "u3", "timestamp": "2026-10-20T10:00:06.000Z",
                           "message": ["role": "user", "content": [
                              ["type": "tool_result", "tool_use_id": "t1", "content": String(repeating: "x", count: 400)],
                           ]]])
        let meta = line(["type": "user", "isMeta": true, "timestamp": "2026-10-20T10:00:00.000Z",
                         "message": ["role": "user", "content": "<local-command-stdout>"]])

        let first = try #require(ContentReader.read(prompt))
        #expect(first.counts.prompts == 13)
        let second = try #require(ContentReader.read(call))
        #expect(second.counts.replies == 11)
        #expect(second.counts.toolCalls > 0)
        #expect(second.toolCalls == ["t1": "Read"])
        let third = try #require(ContentReader.read(result))
        #expect(third.results == ["t1": 400])
        #expect(ContentReader.read(meta) == nil)
        #expect(ContentReader.toolName("mcp__github__get_issue") == "MCP · github")
        #expect(ContentReader.toolName(nil) == "Other")
    }

    @Test func indexerFilesResultsUnderTheirTool() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ta-content-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("projects/-work-app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lines = [
            ["type": "assistant", "uuid": "a", "timestamp": "2026-10-20T10:00:05.000Z",
             "message": ["role": "assistant", "model": "claude-opus-5-5",
                         "content": [["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "swift test"]]]]],
            ["type": "user", "uuid": "b", "timestamp": "2026-10-20T10:00:09.000Z",
             "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": "ok ok ok"]]]],
        ].map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        let text = lines.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: folder.appendingPathComponent("s1.jsonl"))
        // The same lines copied into a forked session.
        try Data(text.utf8).write(to: folder.appendingPathComponent("s2.jsonl"))
        let indexer = LedgerIndexer(directory: nil, claudeRoots: [root.appendingPathComponent("projects")], codexHome: nil,
                                    names: ProjectNames(home: "/nowhere", fileExists: { _ in false }, isDirectory: { _ in false }))
        let ledger = await indexer.update()
        #expect(ledger.content().toolResults == ["Bash": 8])
    }

    @Test func gaugesLiveSessions() {
        var ledger = UsageLedger()
        let now = LogLines.date("2026-10-22T12:00:00.000Z")!
        func add(_ session: String, minutesAgo: Double, context: Int, model: String = "claude-opus-5-5") {
            ledger.add(UsageEvent(provider: .claude, date: now.addingTimeInterval(-minutesAgo * 60), session: session,
                                  project: "app", model: model,
                                  counts: TokenCounts(input: 10, output: 50, cacheRead: context - 10, requests: 1)))
        }
        add("live", minutesAgo: 30, context: 100_000)
        add("live", minutesAgo: 2, context: 250_000)
        add("old", minutesAgo: 60, context: 900_000)
        add("small", minutesAgo: 5, context: 150_000, model: "claude-haiku-4-5-20251001")
        let gauges = ContextGauge.live(in: ledger, now: now)
        #expect(gauges.map(\.session) == ["claude:small", "claude:live"])
        #expect(gauges.first?.window == 200_000)
        #expect(gauges.last.map { abs($0.percent - 25) < 0.01 } == true)
        #expect(ContextGauge.window(model: "claude-sonnet-4-5[1m]") == 1_000_000)
        #expect(ContextGauge.window(model: "claude-sonnet-4-20250514") == 200_000)
    }
}
