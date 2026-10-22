import Foundation

/// Google Antigravity's per-model quotas (they refill every few hours).
///
/// Antigravity has no public usage API; its own local language server answers
/// `GetUserStatus` on a localhost port while the app is open, guarded by a
/// token it receives on its command line. So this only works with Antigravity
/// running, and everything stays on 127.0.0.1.
public actor AntigravityProvider: UsageProvider {
    public nonisolated let id = ProviderID.antigravity

    private let home: URL
    private let session: URLSession

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        self.session = URLSession(configuration: .ephemeral, delegate: LocalhostTrust(), delegateQueue: nil)
    }

    public func isInstalled() async -> Bool {
        let paths = [
            "/Applications/Antigravity.app",
            "/Applications/Antigravity IDE.app",
            home.appendingPathComponent("Applications/Antigravity.app").path,
            home.appendingPathComponent(".gemini/antigravity").path,
        ]
        for path in paths where FileManager.default.fileExists(atPath: path) { return true }
        return false
    }

    struct Server: Sendable, Equatable {
        var pid: Int32
        var csrfToken: String
        var extensionPort: Int?
    }

    public func fetch() async throws -> ProviderSnapshot {
        let listing = try await ProcessRunner.run("/bin/ps", ["-axww", "-o", "pid=,command="])
        let servers = Self.findServers(in: listing.text)
        Log.debug("antigravity: \(servers.count) language servers")
        guard !servers.isEmpty else {
            throw ProviderError.notRunning("Abre Antigravity para leer su cuota: solo la da con la app abierta.")
        }

        // Antigravity can run more than one server (windows, the IDE build); any of them answers.
        var lastError: Error = ProviderError.notRunning("Antigravity se está abriendo; vuelvo a mirar en un momento.")
        for server in servers {
            let lsof = try await ProcessRunner.run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(server.pid), "-iTCP", "-sTCP:LISTEN", "-Fn"])
            var ports = Self.listeningPorts(in: lsof.text)
            if let extensionPort = server.extensionPort { ports.removeAll { $0 == extensionPort }; ports.append(extensionPort) }
            Log.debug("antigravity: pid \(server.pid), ports \(ports)")
            for port in ports {
                for scheme in ["https", "http"] {
                    do {
                        let status = try await userStatus(port: port, scheme: scheme, token: server.csrfToken)
                        return Self.snapshot(from: status)
                    } catch {
                        Log.debug("antigravity: \(scheme)://127.0.0.1:\(port) → \(error)")
                        lastError = error
                    }
                }
            }
        }
        throw lastError
    }

    private func userStatus(port: Int, scheme: String, token: String) async throws -> JSONValue {
        let url = URL(string: "\(scheme)://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/GetUserStatus")!
        let body = #"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","locale":"es"}}"#
        let request = HTTP.request(url, method: "POST", headers: [
            "Content-Type": "application/json",
            "Connect-Protocol-Version": "1",
            "X-Codeium-Csrf-Token": token,
        ], body: Data(body.utf8), timeout: 4)
        let json = try await HTTP.json(request, session: session)
        guard json["userStatus"] != nil else { throw ProviderError.badResponse("Antigravity ha respondido sin cuota.") }
        return json
    }

    // MARK: Parsing

    static func findServers(in psOutput: String) -> [Server] {
        var servers: [Server] = []
        for line in psOutput.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            let lower = text.lowercased()
            guard lower.contains("language_server"), lower.contains("antigravity"),
                  !lower.contains("windsurf") else { continue }
            guard let pid = Int32(text.prefix { $0.isNumber }),
                  let token = argument("--csrf_token", in: text) else { continue }
            servers.append(Server(pid: pid, csrfToken: token,
                                  extensionPort: argument("--extension_server_port", in: text).flatMap { Int($0) }))
        }
        return servers
    }

    private static func argument(_ name: String, in commandLine: String) -> String? {
        guard let range = commandLine.range(of: name) else { return nil }
        var rest = commandLine[range.upperBound...]
        if rest.first == "=" { rest = rest.dropFirst() }
        let value = rest.drop { $0 == " " }.prefix { $0 != " " }
        return value.isEmpty ? nil : String(value)
    }

    /// `lsof -Fn` lines such as "n127.0.0.1:53412" or "n*:53412".
    static func listeningPorts(in lsofOutput: String) -> [Int] {
        var ports: [Int] = []
        for line in lsofOutput.split(separator: "\n") where line.hasPrefix("n") {
            if let colon = line.lastIndex(of: ":"), let port = Int(line[line.index(after: colon)...]), !ports.contains(port) {
                ports.append(port)
            }
        }
        return ports
    }

    static func snapshot(from response: JSONValue, now: Date = Date()) -> ProviderSnapshot {
        let status = response["userStatus"] ?? response
        let plan = status["userTier"]?["name"]?.string
            ?? status["planStatus"]?["planInfo"]?["planName"]?.string
        var windows: [UsageWindow] = []
        let configs = status.first(key: "clientModelConfigs")?.array ?? []
        for config in configs {
            guard let quota = config["quotaInfo"], let label = config["label"]?.string else { continue }
            // Proto JSON leaves out zero values: no remainingFraction means none left.
            let remaining = quota["remainingFraction"]?.double ?? 0
            let used = max(0, min(100, (1 - remaining) * 100))
            let resetsAt = DateParsing.date(quota["resetTime"])
            let untilReset = resetsAt.map { $0.timeIntervalSince(now) } ?? 0
            let duration: TimeInterval = untilReset > 6 * 3600 ? 7 * 86_400 : 5 * 3600
            // "Gemini 3 Flash (Low)", "(Medium)", "(High)" share one quota: one row per model.
            let name = baseModelName(label)
            if let index = windows.firstIndex(where: { $0.id == name }) {
                windows[index].usedPercent = max(windows[index].usedPercent, used)
                if let resetsAt, resetsAt < (windows[index].resetsAt ?? .distantFuture) { windows[index].resetsAt = resetsAt }
            } else {
                windows.append(UsageWindow(id: name, label: name, kind: .model, usedPercent: used,
                                           resetsAt: resetsAt, duration: duration))
            }
        }
        var facts: [Fact] = []
        if let credits = status["planStatus"]?["availablePromptCredits"]?.double {
            facts.append(Fact("Créditos de prompts", Fmt.tokens(credits), symbol: "text.bubble"))
        }
        return ProviderSnapshot(provider: .antigravity, plan: plan, account: status["email"]?.string,
                                windows: windows, facts: facts, fetchedAt: now)
    }
}

/// "Claude Sonnet 4.6 (Thinking)" → "Claude Sonnet 4.6".
func baseModelName(_ label: String) -> String {
    guard label.hasSuffix(")"), let open = label.lastIndex(of: "(") else { return label }
    let base = label[..<open].trimmingCharacters(in: .whitespaces)
    return base.isEmpty ? label : base
}

/// Accepts the self-signed certificate of Antigravity's server, on 127.0.0.1 only.
final class LocalhostTrust: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              ["127.0.0.1", "localhost"].contains(space.host),
              let trust = space.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}
