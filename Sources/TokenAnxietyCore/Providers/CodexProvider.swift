import Foundation

/// ChatGPT plans (Plus, Pro, Business…) through Codex, whose five-hour and
/// weekly windows are the plan's Codex limits.
///
/// The figures come from Codex itself: `codex app-server` answers
/// `account/rateLimits/read` over JSON-RPC and handles its own login,
/// including renewing it. Only when no Codex binary is found does this fall
/// back to the HTTP endpoint Codex uses, with the token in `~/.codex/auth.json`.
public actor CodexProvider: UsageProvider {
    public nonisolated let id = ProviderID.codex

    private let home: URL
    private let session: URLSession

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, session: URLSession = .shared) {
        self.home = home
        self.session = session
    }

    private var codexHome: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent(".codex")
    }

    private var authFile: URL { codexHome.appendingPathComponent("auth.json") }

    public func isInstalled() async -> Bool {
        FileManager.default.isFile(authFile) || findBinary() != nil
    }

    public func fetch() async throws -> ProviderSnapshot {
        guard FileManager.default.isFile(authFile) else {
            throw ProviderError.notLoggedIn(String(localized: "Sign in to Codex with your ChatGPT account."))
        }
        if let binary = findBinary() {
            do {
                return try await fetchViaAppServer(binary)
            } catch let error as ProviderError where error.needsUser {
                throw error
            } catch {
                // An older or broken binary: the HTTP endpoint still works with a fresh token.
                if let snapshot = try? await fetchViaHTTP() { return snapshot }
                throw error
            }
        }
        return try await fetchViaHTTP()
    }

    // MARK: Codex binary

    /// The native binary, newest install first: the desktop app keeps its own up to date.
    func findBinary() -> URL? {
        let fm = FileManager.default
        var candidates = [
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            home.appendingPathComponent(".local/bin/codex"),
        ]
        // npm installs (nvm, Homebrew node…) ship the native binary inside the package.
        let nodeRoots = [home.appendingPathComponent(".nvm/versions/node")]
        for root in nodeRoots {
            let versions = (try? fm.contentsOfDirectory(atPath: root.path))?.sorted().reversed() ?? []
            for version in versions {
                let package = root.appendingPathComponent(version).appendingPathComponent("lib/node_modules/@openai/codex")
                candidates.append(package.appendingPathComponent("node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"))
                candidates.append(package.appendingPathComponent("vendor/aarch64-apple-darwin/codex/codex"))
            }
        }
        return candidates.first { url in
            guard fm.isExecutable(url) else { return false }
            // Skip the npm launcher script: it needs node on PATH.
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            let magic = (try? handle.read(upToCount: 2)) ?? Data()
            return magic != Data("#!".utf8)
        }
    }

    private func fetchViaAppServer(_ binary: URL) async throws -> ProviderSnapshot {
        let server = try AppServerConnection(executable: binary)
        defer { server.close() }
        _ = try await server.request("initialize", params: [
            "clientInfo": ["name": "token-anxiety", "title": "Token Anxiety", "version": AppInfo.version],
        ])
        server.notify("initialized")
        let account = try? await server.request("account/read", params: ["refreshToken": false])
        if account?["requiresOpenaiAuth"]?.bool == true, account?["account"]?.isNull ?? true {
            throw ProviderError.notLoggedIn(String(localized: "Codex is signed out. Open it and sign in with ChatGPT."))
        }
        let limits: JSONValue
        do {
            limits = try await server.request("account/rateLimits/read", params: nil, timeout: 20)
        } catch let error as AppServerConnection.RPCError {
            if error.message.lowercased().contains("auth") || error.message.lowercased().contains("login") {
                throw ProviderError.sessionExpired(String(localized: "Codex's session has expired. Open Codex to renew it."))
            }
            throw ProviderError.badResponse(String(localized: "Codex did not give its limits: \(error.message)"))
        }
        let usage = try? await server.request("account/usage/read", params: nil, timeout: 10)
        return Self.snapshot(account: account, limits: limits, usage: usage)
    }

    // MARK: HTTP fallback

    private func fetchViaHTTP() async throws -> ProviderSnapshot {
        guard let data = try? Data(contentsOf: authFile), let auth = try? JSONValue.parse(data),
              let token = auth["tokens"]?["access_token"]?.string else {
            throw ProviderError.notLoggedIn(String(localized: "Sign in to Codex with your ChatGPT account."))
        }
        var headers = ["Authorization": "Bearer \(token)"]
        if let accountID = auth["tokens"]?["account_id"]?.string { headers["ChatGPT-Account-Id"] = accountID }
        let request = HTTP.request(URL(string: "https://chatgpt.com/backend-api/wham/usage")!, headers: headers)
        do {
            let body = try await HTTP.json(request, session: session)
            let email = auth["tokens"]?["id_token"]?.string.flatMap(JWT.claims)?["email"]?.string
            return Self.snapshot(httpUsage: body, email: email)
        } catch ProviderError.http(let status) where status == 401 || status == 403 {
            throw ProviderError.sessionExpired(String(localized: "Codex's session has expired. Open Codex to renew it."))
        }
    }

    // MARK: Parsing

    static func planName(_ raw: String?) -> String? {
        guard let raw = raw?.lowercased(), !raw.isEmpty, raw != "unknown" else { return nil }
        switch raw {
        case "prolite": return "Pro Lite"
        case "self_serve_business_usage_based": return "Business"
        case "enterprise_cbp_usage_based": return "Enterprise"
        default: return Fmt.planName(raw)
        }
    }

    /// `account/rateLimits/read` (+ `account/read`, `account/usage/read`).
    static func snapshot(account: JSONValue?, limits: JSONValue, usage: JSONValue?, now: Date = Date()) -> ProviderSnapshot {
        var windows: [UsageWindow] = []
        var facts: [Fact] = []
        let main = limits["rateLimits"] ?? .object([:])

        for (slot, window) in [("primary", main["primary"]), ("secondary", main["secondary"])] {
            if let window, let parsed = rpcWindow(window, id: slot, prefix: nil) { windows.append(parsed) }
        }

        // Other metered buckets (the main one is already in `rateLimits`).
        let mainID = main["limitId"]?.string
        for (limitID, bucket) in (limits["rateLimitsByLimitId"]?.object ?? [:]).sorted(by: { $0.key < $1.key })
        where limitID != mainID && limitID != "codex" {
            let name = bucket["limitName"]?.string ?? Fmt.planName(limitID)
            for slot in ["primary", "secondary"] {
                if let window = bucket[slot], var parsed = rpcWindow(window, id: "\(limitID).\(slot)", prefix: name) {
                    parsed.kind = .other
                    windows.append(parsed)
                }
            }
        }

        if let spend = main["individualLimit"], let remaining = spend["remainingPercent"]?.double {
            windows.append(UsageWindow(id: "spend", label: String(localized: "Spending limit"), kind: .other,
                                       usedPercent: 100 - remaining, resetsAt: DateParsing.date(spend["resetsAt"]),
                                       detail: [spend["used"]?.string, spend["limit"]?.string].compactMap { $0 }.joined(separator: " / ")))
        }

        if let credits = main["credits"] {
            if credits["unlimited"]?.bool == true {
                facts.append(Fact(String(localized: "Credits"), String(localized: "unlimited"), symbol: "infinity"))
            } else if credits["hasCredits"]?.bool == true, let balance = credits["balance"]?.string {
                facts.append(Fact(String(localized: "Credits"), balance, symbol: "creditcard"))
            }
        }
        if let resets = limits["rateLimitResetCredits"]?["availableCount"]?.int, resets > 0 {
            facts.append(Fact(String(localized: "Limit resets"), resets == 1 ? String(localized: "1 available") : String(localized: "\(resets) available"),
                               symbol: "arrow.counterclockwise"))
        }
        if main["rateLimitReachedType"]?.string != nil {
            facts.append(Fact(String(localized: "Status"), String(localized: "limit reached"), symbol: "exclamationmark.octagon"))
        }

        var daily: [DayValue] = []
        if let summary = usage?["summary"] {
            if let streak = summary["currentStreakDays"]?.int, streak > 0 {
                facts.append(Fact(String(localized: "Streak"), streak == 1 ? String(localized: "1 day in a row") : String(localized: "\(streak) days in a row"),
                                   symbol: "flame"))
            }
            if let lifetime = summary["lifetimeTokens"]?.double, lifetime > 0 {
                facts.append(Fact(String(localized: "Lifetime tokens"), Fmt.tokens(lifetime), symbol: "sum"))
            }
        }
        for bucket in usage?["dailyUsageBuckets"]?.array ?? [] {
            guard let day = parseDay(bucket["startDate"]?.string), let tokens = bucket["tokens"]?.double else { continue }
            daily.append(DayValue(day: day, value: tokens))
        }

        let plan = planName(account?["account"]?["planType"]?.string ?? main["planType"]?.string)
        return ProviderSnapshot(provider: .codex, plan: plan, account: account?["account"]?["email"]?.string,
                                windows: windows, facts: facts, dailyTokens: daily.sorted { $0.day < $1.day },
                                fetchedAt: now)
    }

    private static func rpcWindow(_ value: JSONValue, id: String, prefix: String?) -> UsageWindow? {
        guard let used = value["usedPercent"]?.double else { return nil }
        let minutes = value["windowDurationMins"]?.double
        return window(id: id, prefix: prefix, used: used, minutes: minutes, resetsAt: DateParsing.date(value["resetsAt"]))
    }

    /// The HTTP endpoint's shape (`wham/usage`).
    static func snapshot(httpUsage body: JSONValue, email: String?, now: Date = Date()) -> ProviderSnapshot {
        var windows: [UsageWindow] = []
        let limits = body["rate_limit"]
        for slot in ["primary_window", "secondary_window"] {
            guard let value = limits?[slot], let used = value["used_percent"]?.double else { continue }
            let minutes = value["limit_window_seconds"]?.double.map { $0 / 60 }
            var resetsAt = DateParsing.date(value["reset_at"])
            if resetsAt == nil, let after = value["reset_after_seconds"]?.double { resetsAt = now.addingTimeInterval(after) }
            windows.append(window(id: slot == "primary_window" ? "primary" : "secondary", prefix: nil,
                                  used: used, minutes: minutes, resetsAt: resetsAt))
        }
        var facts: [Fact] = []
        if let credits = body["credits"] {
            if credits["unlimited"]?.bool == true {
                facts.append(Fact(String(localized: "Credits"), String(localized: "unlimited"), symbol: "infinity"))
            } else if credits["has_credits"]?.bool == true, let balance = credits["balance"]?.string {
                facts.append(Fact(String(localized: "Credits"), balance, symbol: "creditcard"))
            }
        }
        return ProviderSnapshot(provider: .codex, plan: planName(body["plan_type"]?.string), account: email,
                                windows: windows, facts: facts, fetchedAt: now)
    }

    private static func window(id: String, prefix: String?, used: Double, minutes: Double?, resetsAt: Date?) -> UsageWindow {
        let label: String
        let kind: WindowKind
        switch minutes {
        case .some(let m) where m >= 280 && m <= 320:
            (label, kind) = (String(localized: "Session · 5 h"), .session)
        case .some(let m) where m >= 9_800 && m <= 10_300:
            (label, kind) = (String(localized: "Week"), .weekly)
        case .some(let m) where m >= 40_000:
            (label, kind) = (String(localized: "Month"), .monthly)
        case .some(let m) where m >= 1440:
            (label, kind) = (String(localized: "\(Int((m / 1440).rounded())) days"), .other)
        case .some(let m):
            (label, kind) = ("\(Int((m / 60).rounded())) h", .other)
        case .none:
            (label, kind) = (id == "primary" ? String(localized: "Session · 5 h") : String(localized: "Week"), id == "primary" ? .session : .weekly)
        }
        let duration = minutes.map { $0 * 60 } ?? (kind == .session ? 5 * 3600 : kind == .weekly ? 7 * 86_400 : nil)
        return UsageWindow(id: id, label: prefix.map { "\($0) · \(label)" } ?? label, kind: kind,
                           usedPercent: used, resetsAt: resetsAt, duration: duration)
    }

    private static func parseDay(_ text: String?) -> Date? {
        guard let text else { return nil }
        if let date = DateParsing.iso8601(text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(text.prefix(10)))
    }
}

/// A short-lived `codex app-server` over stdio: newline-delimited JSON-RPC
/// (without the "jsonrpc" field, as Codex speaks it).
final class AppServerConnection: @unchecked Sendable {
    struct RPCError: Error {
        let code: Int
        let message: String
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let state = Locked(State())

    private struct State {
        var buffer = Data()
        var nextID = 0
        var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
        var closed = false
    }

    init(executable: URL) throws {
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.environment = ProcessRunner.environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.failAll(ProviderError.badResponse(String(localized: "Codex quit without answering.")))
            } else {
                self?.receive(data)
            }
        }
        do {
            try process.run()
        } catch {
            throw ProviderError.badResponse(String(localized: "Could not start Codex: \(error.localizedDescription)"))
        }
    }

    func request(_ method: String, params: [String: Any]?, timeout: TimeInterval = 10) async throws -> JSONValue {
        let id = state.withLock { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        var message: [String: Any] = ["id": id, "method": method]
        if let params { message["params"] = params }
        let line = try JSONSerialization.data(withJSONObject: message) + Data("\n".utf8)

        return try await withCheckedThrowingContinuation { continuation in
            let closed = state.withLock { state -> Bool in
                if state.closed { return true }
                state.pending[id] = continuation
                return false
            }
            if closed {
                continuation.resume(throwing: ProviderError.badResponse(String(localized: "Codex quit.")))
                return
            }
            do {
                try input.fileHandleForWriting.write(contentsOf: line)
            } catch {
                resolve(id, with: .failure(ProviderError.badResponse(String(localized: "Could not talk to Codex."))))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolve(id, with: .failure(ProviderError.network(String(localized: "Codex took too long to answer."))))
            }
        }
    }

    func notify(_ method: String) {
        guard let line = try? JSONSerialization.data(withJSONObject: ["method": method]) else { return }
        try? input.fileHandleForWriting.write(contentsOf: line + Data("\n".utf8))
    }

    func close() {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        failAll(ProviderError.badResponse(String(localized: "Codex quit.")))
    }

    private func receive(_ data: Data) {
        let lines = state.withLock { state -> [Data] in
            state.buffer.append(data)
            var lines: [Data] = []
            while let newline = state.buffer.firstIndex(of: 0x0A) {
                lines.append(state.buffer[state.buffer.startIndex..<newline])
                state.buffer.removeSubrange(state.buffer.startIndex...newline)
            }
            return lines
        }
        for line in lines {
            guard let message = try? JSONValue.parse(Data(line)), let id = message["id"]?.int,
                  message["method"] == nil else { continue } // notifications and server requests are ignored
            if let error = message["error"] {
                resolve(id, with: .failure(RPCError(code: error["code"]?.int ?? 0,
                                                    message: error["message"]?.string ?? "error")))
            } else {
                resolve(id, with: .success(message["result"] ?? .null))
            }
        }
    }

    private func resolve(_ id: Int, with result: Result<JSONValue, Error>) {
        let continuation = state.withLock { $0.pending.removeValue(forKey: id) }
        continuation?.resume(with: result)
    }

    private func failAll(_ error: Error) {
        let pending = state.withLock { state -> [CheckedContinuation<JSONValue, Error>] in
            state.closed = true
            defer { state.pending.removeAll() }
            return Array(state.pending.values)
        }
        for continuation in pending { continuation.resume(throwing: error) }
    }
}
