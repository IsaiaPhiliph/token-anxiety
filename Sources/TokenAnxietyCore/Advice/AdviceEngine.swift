import Foundation

/// Who answers the advice request.
///
/// The plans' own command-line tools run on this Mac with the user's own login, the way
/// they are meant to be scripted (`claude -p`, `codex exec`): the request counts toward
/// that plan's limits like any other, and no session token is taken out of them (Anthropic
/// does not allow a subscription's token to be used by other apps).
public enum AdviceEngine: String, CaseIterable, Identifiable, Sendable {
    case claudeCode, codex, api

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .api: String(localized: "API key")
        }
    }

    /// The command-line tool, if it is on this Mac (nil for the API).
    public func executable(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        switch self {
        case .claudeCode: AdviceCommand.claudeBinary(home: home)
        case .codex: CodexProvider.binary(home: home)
        case .api: nil
        }
    }
}

/// One run of a plan's command-line tool, written out so the user can read it before it runs.
public struct AdviceCommand: Sendable, Equatable {
    public var engine: AdviceEngine
    public var executable: URL
    public var arguments: [String]
    /// What the tool reads on stdin: the aggregates (and, for Codex, the instructions).
    public var input: String
    /// An empty folder of its own: nothing from a project is in reach, and the tool's
    /// files (schema, answer) live there.
    public var directory: URL

    /// Claude Code, newest install first: the native installer, the old local install, Homebrew.
    static func claudeBinary(home: URL) -> URL? {
        let fm = FileManager.default
        let candidates = [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        return candidates.first { fm.isExecutable($0) }
    }

    public static func make(engine: AdviceEngine, executable: URL, summary: [String: Any], language: String,
                            directory: URL) -> AdviceCommand {
        let schema = String(decoding: (try? JSONSerialization.data(withJSONObject: Advice.schema, options: [.sortedKeys])) ?? Data(),
                            as: UTF8.self)
        let message = Advice.message(summary: summary)
        switch engine {
        case .codex:
            return AdviceCommand(engine: engine, executable: executable, arguments: [
                "exec", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config",
                "--sandbox", "read-only", "--color", "never",
                "-c", "model_reasoning_effort=\"medium\"",
                "--output-schema", directory.appendingPathComponent("schema.json").path,
                "--output-last-message", directory.appendingPathComponent("answer.json").path,
                "-",
            ], input: Advice.instructions(language: language)
                + " Answer from the data below alone; do not run commands or read files.\n\n" + message,
            directory: directory)
        default:
            return AdviceCommand(engine: engine, executable: executable, arguments: [
                "-p", "--output-format", "json",
                "--model", Advice.model, "--fallback-model", "sonnet", "--effort", "medium",
                // No tools, MCP servers, skills, settings (hooks) or saved session: one plain answer.
                "--tools", "", "--strict-mcp-config", "--disable-slash-commands", "--setting-sources", "project",
                "--no-session-persistence",
                "--system-prompt", Advice.instructions(language: language),
                "--json-schema", schema,
            ], input: message, directory: directory)
        }
    }

    /// The command as it would be typed in a terminal, and what it reads on stdin.
    public var preview: String {
        let command = ([executable.path] + arguments).map(Self.quoted).joined(separator: " ")
        return "$ cd \(Self.quoted(directory.path))\n$ \(command) <<'EOF'\n\(input)\nEOF"
    }

    static func quoted(_ text: String) -> String {
        guard text.isEmpty || text.contains(where: { " \"'$`\\\n{}[]*?&;|<>()".contains($0) }) else { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Running

    public func run(timeout: TimeInterval = 300) async throws -> [Advice.Tip] {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        if engine == .codex {
            try JSONSerialization.data(withJSONObject: Advice.schema, options: [.sortedKeys])
                .write(to: directory.appendingPathComponent("schema.json"))
        }
        // npm installs need `node`, next to the tool.
        let output = try await ProcessRunner.run(executable.path, arguments, input: Data(input.utf8), timeout: timeout,
                                                 directory: directory,
                                                 extraPath: [executable.deletingLastPathComponent().path])
        switch engine {
        case .codex:
            guard output.status == 0 else { throw Self.failure(output) }
            let answer = try? String(contentsOf: directory.appendingPathComponent("answer.json"), encoding: .utf8)
            return try Advice.tips(fromJSONText: answer)
        default:
            return try Self.claudeTips(output.stdout, status: output.status, errorText: output.errorText)
        }
    }

    /// `claude -p --output-format json`: one result object, with `structured_output` when a
    /// schema was given (older versions only have the text in `result`).
    static func claudeTips(_ stdout: Data, status: Int32, errorText: String = "") throws -> [Advice.Tip] {
        guard let json = try? JSONValue.parse(stdout) else {
            throw Advice.Failure.tool(lastLine(errorText) ?? String(localized: "Claude Code did not answer (\(Int(status)))."))
        }
        if json["is_error"]?.bool == true || json["subtype"]?.string?.hasPrefix("error") == true {
            throw Advice.Failure.tool(json["result"]?.string ?? lastLine(errorText) ?? String(localized: "Claude Code could not answer."))
        }
        if let structured = json["structured_output"], let data = try? JSONEncoder().encode(structured),
           let tips = try? Advice.tips(fromJSONText: String(decoding: data, as: UTF8.self)) {
            return tips
        }
        return try Advice.tips(fromJSONText: json["result"]?.string)
    }

    private static func failure(_ output: ProcessRunner.Output) -> Advice.Failure {
        .tool(lastLine(output.errorText) ?? lastLine(output.text) ?? String(localized: "The tool stopped with an error (\(Int(output.status)))."))
    }

    private static func lastLine(_ text: String) -> String? {
        let lines: [String] = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.last { !$0.isEmpty }
    }
}
