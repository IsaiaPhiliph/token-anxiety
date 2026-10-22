import Foundation
import Testing
@testable import TokenAnxietyCore

/// Answers every request with a canned response and remembers what was asked.
final class FakeAnthropic: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var answer = Data()
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.answer)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeAnthropic.self]
        return URLSession(configuration: configuration)
    }

    static func message(tips: String, stop: String = "end_turn") -> Data {
        let text = try! JSONSerialization.data(withJSONObject: ["tips": try! JSONSerialization.jsonObject(with: Data(tips.utf8))])
        let message: [String: Any] = [
            "id": "msg_1", "type": "message", "role": "assistant", "model": "claude-opus-5-5", "stop_reason": stop,
            "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": String(decoding: text, as: UTF8.self)]],
            "usage": ["input_tokens": 900, "output_tokens": 300],
        ]
        return try! JSONSerialization.data(withJSONObject: message)
    }
}

@Suite(.serialized) struct AdviceTests {
    private func ledger() -> UsageLedger {
        var ledger = UsageLedger()
        let now = LogLines.date("2026-10-22T12:00:00.000Z")!
        for hour in 0..<48 {
            ledger.add(UsageEvent(provider: .claude, date: now.addingTimeInterval(-Double(hour) * 3600), session: "s\(hour % 5)",
                                  project: "secret-client-project", branch: "main", model: "claude-opus-5-5", effort: "high",
                                  counts: TokenCounts(input: 5, output: 800, cacheWrite5m: 2_000, cacheRead: 90_000, requests: 1)))
        }
        var content = ContentCounts()
        content.prompts = 4_000
        content.toolResults = ["Bash": 90_000, "Read": 40_000]
        ledger.addContent(content, date: now.addingTimeInterval(-3600))
        return ledger
    }

    private let now = LogLines.date("2026-10-22T12:30:00.000Z")!

    @Test func sendsOnlyAggregatesAndProjectsWhenAsked() throws {
        let summary = Advice.summary(ledger: ledger(), now: now, plans: [.claude: "Max 20x"], weeklyUsed: [.claude: 52])
        let text = String(decoding: Advice.body(summary: summary, language: "Spanish"), as: UTF8.self)
        #expect(!text.contains("secret-client-project"))
        #expect(text.contains("Max 20x"))
        #expect(text.contains("Bash"))
        let withProjects = Advice.summary(ledger: ledger(), now: now, includeProjects: true)
        #expect(String(decoding: Advice.body(summary: withProjects, language: "English"), as: UTF8.self)
            .contains("secret-client-project"))
    }

    @Test func buildsAStructuredOutputRequest() throws {
        let body = Advice.body(summary: Advice.summary(ledger: ledger(), now: now), language: "Spanish")
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "claude-opus-5-5")
        #expect(json["fallbacks"] as? String == "default")
        #expect(json["thinking"] == nil) // thinking is always on for Opus 5.5
        let config = try #require(json["output_config"] as? [String: Any])
        #expect(config["effort"] as? String == "medium")
        let format = try #require(config["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect((json["system"] as? String)?.contains("Spanish") == true)
    }

    @Test func sendsWithTheKeyAndReadsTheTips() async throws {
        FakeAnthropic.status = 200
        FakeAnthropic.answer = FakeAnthropic.message(tips: #"[{"title":"Trim Bash output","evidence":"Bash results are 64% of tool output.","action":"Pipe long commands through tail."}]"#)
        let body = Advice.body(summary: Advice.summary(ledger: ledger(), now: now), language: "English")
        let tips = try await Advice.send(body: body, apiKey: "sk-ant-test", session: FakeAnthropic.session)
        #expect(tips == [Advice.Tip(title: "Trim Bash output", evidence: "Bash results are 64% of tool output.",
                                    action: "Pipe long commands through tail.")])
        let request = try #require(FakeAnthropic.lastRequest)
        #expect(request.url == Advice.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        #expect(FakeAnthropic.lastBody == body) // exactly what the preview showed
    }

    @Test func reportsRefusalsAndErrors() async throws {
        FakeAnthropic.status = 200
        FakeAnthropic.answer = FakeAnthropic.message(tips: "[]", stop: "refusal")
        await #expect(throws: Advice.Failure.refused) {
            try await Advice.send(body: Data("{}".utf8), apiKey: "k", session: FakeAnthropic.session)
        }
        FakeAnthropic.status = 401
        FakeAnthropic.answer = Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)
        await #expect(throws: Advice.Failure.api(status: 401, message: "invalid x-api-key")) {
            try await Advice.send(body: Data("{}".utf8), apiKey: "k", session: FakeAnthropic.session)
        }
    }
}

@Suite struct AdviceCommandTests {
    private let summary: [String: Any] = ["period_days": 30, "totals": ["tokens": 1234]]
    private let folder = URL(fileURLWithPath: "/tmp/advice-test")

    @Test func claudeCodeRunsBareAndSavesNothing() {
        let command = AdviceCommand.make(engine: .claudeCode, executable: URL(fileURLWithPath: "/bin/claude"),
                                         summary: summary, language: "Spanish", directory: folder)
        let arguments = command.arguments
        #expect(arguments.first == "-p")
        for flag in ["--no-session-persistence", "--strict-mcp-config", "--disable-slash-commands", "--json-schema", "--system-prompt"] {
            #expect(arguments.contains(flag))
        }
        #expect(arguments[arguments.firstIndex(of: "--tools")! + 1] == "")
        #expect(arguments[arguments.firstIndex(of: "--model")! + 1] == Advice.model)
        #expect(command.input.contains("\"tokens\" : 1234"))
        #expect(command.preview.contains("--tools ''"))
        #expect(command.preview.hasPrefix("$ cd /tmp/advice-test"))
    }

    @Test func codexRunsEphemeralAndReadOnly() {
        let command = AdviceCommand.make(engine: .codex, executable: URL(fileURLWithPath: "/bin/codex"),
                                         summary: summary, language: "English", directory: folder)
        let arguments = command.arguments
        #expect(arguments.first == "exec")
        #expect(arguments.last == "-")
        for flag in ["--ephemeral", "--skip-git-repo-check", "--ignore-user-config"] { #expect(arguments.contains(flag)) }
        #expect(arguments[arguments.firstIndex(of: "--sandbox")! + 1] == "read-only")
        #expect(arguments[arguments.firstIndex(of: "--output-schema")! + 1] == "/tmp/advice-test/schema.json")
        #expect(command.input.hasPrefix(Advice.instructions(language: "English")))
    }

    @Test func readsClaudeCodeAnswers() throws {
        let tip = #"{"title":"T","evidence":"E","action":"A"}"#
        let structured = Data(#"{"type":"result","subtype":"success","is_error":false,"result":"","structured_output":{"tips":[\#(tip)]}}"#.utf8)
        #expect(try AdviceCommand.claudeTips(structured, status: 0) == [Advice.Tip(title: "T", evidence: "E", action: "A")])
        let fenced = try JSONSerialization.data(withJSONObject: ["type": "result", "is_error": false,
                                                                 "result": "```json\n{\"tips\":[\(tip)]}\n```"])
        #expect(try AdviceCommand.claudeTips(fenced, status: 0).count == 1)
        let failed = Data(#"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Not logged in"}"#.utf8)
        #expect(throws: Advice.Failure.tool("Not logged in")) { try AdviceCommand.claudeTips(failed, status: 1) }
        #expect(throws: Advice.Failure.tool("Invalid API key · Please run /login")) {
            try AdviceCommand.claudeTips(Data(), status: 1, errorText: "warning\nInvalid API key · Please run /login\n")
        }
    }

    @Test func quotesLikeAShell() {
        #expect(AdviceCommand.quoted("plain") == "plain")
        #expect(AdviceCommand.quoted("") == "''")
        #expect(AdviceCommand.quoted("it's") == "'it'\\''s'")
    }
}
