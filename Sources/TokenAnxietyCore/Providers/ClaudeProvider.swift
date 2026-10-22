import Foundation

/// Claude (Pro/Max) through the session Claude Code keeps on this Mac.
///
/// Claude Code stores its OAuth login in the Keychain ("Claude Code-credentials").
/// It is read with `/usr/bin/security`, which that item already trusts, and the
/// access token goes only to Anthropic's usage endpoint, the one `/usage` reads.
///
/// The access token lasts eight hours and only the CLI renews it, so with the
/// user's consent (`renewalDefaultsKey`, on by default) an expired session is
/// renewed here the way Claude Code does it and written back to the same item,
/// keeping every other field, so Claude Code carries on with the new tokens.
public actor ClaudeProvider: UsageProvider {
    public nonisolated let id = ProviderID.claude

    public static let renewalDefaultsKey = "renewClaudeSession"
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let keychainService = "Claude Code-credentials"
    /// Claude Code's public OAuth client.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenURLs = [
        URL(string: "https://console.anthropic.com/v1/oauth/token")!,
        URL(string: "https://platform.claude.com/v1/oauth/token")!,
    ]

    struct Credentials: Sendable {
        var accessToken: String
        var expiresAt: Date?
        var subscriptionType: String?
        var rateLimitTier: String?

        func isExpired(now: Date = Date()) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt <= now.addingTimeInterval(30)
        }
    }

    /// The stored JSON as read, and where it lives, so a renewal can write it back.
    struct Stored: Sendable {
        enum Location: Sendable {
            case keychain(account: String)
            case file(URL)
        }

        var data: Data
        var location: Location
    }

    private let home: URL
    private let session: URLSession
    private var stored: Stored?
    private var credentials: Credentials?
    private var renewal: Task<Credentials, Error>?
    private var lastRenewalFailure: Date?
    /// A refresh token Anthropic refused; it is not sent again until a new login replaces it.
    private var refusedRefreshToken: String?

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, session: URLSession = .shared) {
        self.home = home
        self.session = session
    }

    private var configDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent(".claude")
    }

    public func isInstalled() async -> Bool {
        let fm = FileManager.default
        return fm.isFile(home.appendingPathComponent(".claude.json"))
            || fm.fileExists(atPath: configDirectory.path)
    }

    public func fetch() async throws -> ProviderSnapshot {
        var credentials = try await loadCredentials(reload: false)
        if credentials.isExpired() {
            // Claude Code may have renewed it since the last read.
            credentials = try await loadCredentials(reload: true)
        }
        if credentials.isExpired() { credentials = try await renew() }

        let usage: JSONValue
        do {
            usage = try await requestUsage(credentials)
        } catch ProviderError.http(let status) where status == 401 || status == 403 {
            let rejected = credentials.accessToken
            credentials = try await loadCredentials(reload: true)
            if credentials.isExpired() || credentials.accessToken == rejected { credentials = try await renew() }
            do {
                usage = try await requestUsage(credentials)
            } catch ProviderError.http(let status) where status == 401 || status == 403 {
                throw Self.expired
            }
        }

        let account = readAccount()
        let plan = Self.planName(subscriptionType: credentials.subscriptionType,
                                 rateLimitTier: credentials.rateLimitTier ?? account.rateLimitTier)
        return Self.snapshot(from: usage, plan: plan, account: account.email)
    }

    static let needsLogin = ProviderError.sessionExpired(
        "Claude Code ya no puede renovar su sesión. Abre «claude» en una terminal y haz /login; después la app la mantendrá viva."
    )

    static let expired = ProviderError.sessionExpired(
        "La sesión de Claude Code ha caducado. Abre Claude Code (o usa «claude») y se renovará sola."
    )

    private func requestUsage(_ credentials: Credentials) async throws -> JSONValue {
        let request = HTTP.request(Self.usageURL, headers: [
            "Authorization": "Bearer \(credentials.accessToken)",
            "anthropic-beta": "oauth-2025-04-20",
        ])
        return try await HTTP.json(request, session: session)
    }

    // MARK: Credentials

    private func loadCredentials(reload: Bool) async throws -> Credentials {
        if !reload, let credentials { return credentials }
        guard let stored = try await readStored() else {
            throw ProviderError.notLoggedIn("Inicia sesión en Claude Code («claude», luego /login) con tu cuenta Pro o Max.")
        }
        let parsed = Self.parseCredentials(stored.data)
        Log.debug("claude: token \(parsed == nil ? "missing" : "present"), expires \(parsed?.expiresAt.map { "\($0)" } ?? "?"), plan \(parsed?.subscriptionType ?? "?")")
        guard let parsed else {
            throw ProviderError.notLoggedIn("Claude Code no tiene una sesión con tu suscripción (¿usas una clave de API?).")
        }
        self.stored = stored
        credentials = parsed
        return parsed
    }

    private func readStored() async throws -> Stored? {
        if let (data, account) = try await readKeychain() {
            return Stored(data: data, location: .keychain(account: account))
        }
        let file = configDirectory.appendingPathComponent(".credentials.json")
        if let data = try? Data(contentsOf: file) { return Stored(data: data, location: .file(file)) }
        return nil
    }

    private func readKeychain() async throws -> (Data, String)? {
        var account = NSUserName()
        var output = try await ProcessRunner.run(
            "/usr/bin/security",
            ["find-generic-password", "-s", Self.keychainService, "-a", account, "-w"],
            timeout: 60 // macOS may be asking the user for permission
        )
        if output.status == 44 {
            // Saved under another account name: find which, to be able to write it back.
            let attributes = try await ProcessRunner.run("/usr/bin/security", ["find-generic-password", "-s", Self.keychainService])
            guard attributes.status == 0, let found = Self.accountAttribute(attributes.text) else { return nil }
            account = found
            output = try await ProcessRunner.run(
                "/usr/bin/security", ["find-generic-password", "-s", Self.keychainService, "-a", account, "-w"], timeout: 60
            )
        }
        Log.debug("claude: keychain exit \(output.status), \(output.stdout.count) bytes")
        if output.status == 44 { return nil } // errSecItemNotFound
        guard output.status == 0 else {
            throw ProviderError.accessDenied("macOS no ha dejado leer la sesión de Claude Code del llavero. Pulsa «Reintentar» y elige «Permitir siempre».")
        }
        let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // `security -w` prints non-UTF-8 secrets as hex.
        if !text.hasPrefix("{"), let decoded = Data(hexString: text) { return (decoded, account) }
        return (Data(text.utf8), account)
    }

    /// `"acct"<blob>="name"` in `security find-generic-password` output.
    static func accountAttribute(_ text: String) -> String? {
        guard let line = text.split(separator: "\n").first(where: { $0.contains("\"acct\"<blob>=\"") }),
              let start = line.range(of: "<blob>=\"")?.upperBound,
              let end = line[start...].lastIndex(of: "\"") else { return nil }
        return String(line[start..<end])
    }

    // MARK: Renewal

    /// One renewal at a time: a second refresh with the same refresh token would
    /// be rejected and could sign Claude Code out.
    private func renew() async throws -> Credentials {
        if let renewal { return try await renewal.value }
        let task = Task { try await self.performRenewal() }
        renewal = task
        defer { renewal = nil }
        return try await task.value
    }

    private func performRenewal() async throws -> Credentials {
        let enabled = UserDefaults.standard.object(forKey: Self.renewalDefaultsKey) as? Bool ?? true
        guard enabled else { throw Self.expired }
        if let lastRenewalFailure, Date().timeIntervalSince(lastRenewalFailure) < 15 * 60 { throw Self.expired }
        guard let stored, let refreshToken = Self.refreshToken(in: stored.data) else { throw Self.expired }
        if refreshToken == refusedRefreshToken { throw Self.needsLogin }

        let response: JSONValue
        do {
            response = try await requestRefresh(refreshToken)
        } catch let error as ProviderError where error == Self.needsLogin {
            refusedRefreshToken = refreshToken
            throw error
        } catch {
            lastRenewalFailure = Date()
            Log.notice("claude: renewal failed: \(error)")
            throw error
        }
        guard let updated = Self.renewedCredentials(stored.data, response: response),
              let parsed = Self.parseCredentials(updated) else {
            lastRenewalFailure = Date()
            Log.notice("claude: renewal answered without an access token")
            throw ProviderError.badResponse("Anthropic ha renovado la sesión con una respuesta que no entiendo.")
        }
        // The old refresh token may be spent now: the new one must reach Claude Code's storage.
        let renewed = Stored(data: updated, location: stored.location)
        self.stored = renewed
        credentials = parsed
        do {
            try await write(renewed)
        } catch {
            Log.notice("claude: renewed but not saved: \(error)")
            throw ProviderError.badResponse("He renovado la sesión de Claude Code pero no la he podido guardar. Si Claude Code te pide entrar, haz /login.")
        }
        Log.notice("claude: session renewed until \(parsed.expiresAt.map { "\($0)" } ?? "?")")
        return parsed
    }

    private func requestRefresh(_ refreshToken: String) async throws -> JSONValue {
        let body = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
        ])
        var lastError: Error = Self.expired
        var refused = false
        for url in Self.tokenURLs {
            let request = HTTP.request(url, method: "POST", headers: ["Content-Type": "application/json"], body: body)
            let data: Data
            let status: Int
            do {
                (data, status) = try await HTTP.send(request, session: session)
            } catch {
                lastError = error
                continue
            }
            switch status {
            case 200..<300:
                guard let json = try? JSONValue.parse(data) else { throw ProviderError.badResponse("Respuesta de renovación ilegible.") }
                return json
            case 400, 401, 403:
                let reason = (try? JSONValue.parse(data)).flatMap { $0["error"]?.string ?? $0["error"]?["type"]?.string } ?? "?"
                Log.notice("claude: renewal refused (\(status), \(reason))")
                // A refused token was not rotated, so asking the other host is harmless.
                refused = refused || reason.contains("invalid_grant")
                lastError = ProviderError.http(status)
            case 429:
                throw ProviderError.http(429)
            default:
                lastError = ProviderError.http(status) // 404 or 5xx: try the other host
            }
        }
        if refused { throw Self.needsLogin }
        throw lastError
    }

    private func write(_ stored: Stored) async throws {
        switch stored.location {
        case .file(let url):
            try stored.data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        case .keychain(let account):
            let (arguments, input) = Self.keychainWrite(stored.data, account: account)
            Log.debug("claude: saving \(stored.data.count) bytes \(input == nil ? "as arguments" : "on stdin")")
            _ = try await ProcessRunner.run("/usr/bin/security", arguments, input: input, timeout: 30)
            // `security -i` does not report failures in its exit status: read it back.
            guard let (saved, _) = try await readKeychain(), saved == stored.data else {
                throw ProviderError.badResponse("keychain write not confirmed")
            }
        }
    }

    /// `security -i` reads its commands in lines of up to 4095 bytes and runs a longer
    /// line in pieces, the first of which would save a truncated item.
    static let interactiveLineLimit = 4095

    /// How `security` saves `data` in the item: on stdin, which keeps the secret out of
    /// `ps`, while the command fits on one line. Claude Code's item also keeps its MCP
    /// servers' logins and soon outgrows that, so then it goes as arguments, which `ps`
    /// shows for the moment `security` runs.
    static func keychainWrite(_ data: Data, account: String) -> (arguments: [String], input: Data?) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let line = "add-generic-password -U -a \"\(account)\" -s \"\(keychainService)\" -X \(hex)\n"
        if line.utf8.count <= interactiveLineLimit, !account.contains("\"") {
            return (["-i"], Data(line.utf8))
        }
        return (["add-generic-password", "-U", "-a", account, "-s", keychainService, "-X", hex], nil)
    }

    static func refreshToken(in data: Data) -> String? {
        guard let json = try? JSONValue.parse(data) else { return nil }
        return (json["claudeAiOauth"] ?? json)["refreshToken"]?.string
    }

    /// The stored JSON with the new tokens, every other field untouched.
    static func renewedCredentials(_ data: Data, response: JSONValue, now: Date = Date()) -> Data? {
        guard let accessToken = response["access_token"]?.string, !accessToken.isEmpty,
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let nested = root["claudeAiOauth"] is [String: Any]
        var oauth = (nested ? root["claudeAiOauth"] as? [String: Any] : root) ?? [:]
        oauth["accessToken"] = accessToken
        if let refreshToken = response["refresh_token"]?.string, !refreshToken.isEmpty { oauth["refreshToken"] = refreshToken }
        let lifetime = response["expires_in"]?.double ?? 8 * 3600
        oauth["expiresAt"] = Int64((now.timeIntervalSince1970 + lifetime) * 1000)
        if let scope = response["scope"]?.string, !scope.isEmpty {
            oauth["scopes"] = scope.split(separator: " ").map(String.init)
        }
        if nested { root["claudeAiOauth"] = oauth } else { root = oauth }
        return try? JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes])
    }

    static func parseCredentials(_ data: Data) -> Credentials? {
        guard let json = try? JSONValue.parse(data) else { return nil }
        let oauth = json["claudeAiOauth"] ?? json
        guard let token = oauth["accessToken"]?.string, !token.isEmpty else { return nil }
        return Credentials(
            accessToken: token,
            expiresAt: DateParsing.unix(oauth["expiresAt"]?.double),
            subscriptionType: oauth["subscriptionType"]?.string,
            rateLimitTier: oauth["rateLimitTier"]?.string
        )
    }

    /// Email and tier from `~/.claude.json`, which holds no secrets.
    private func readAccount() -> (email: String?, rateLimitTier: String?) {
        let url = home.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = object["oauthAccount"] as? [String: Any] else { return (nil, nil) }
        let tier = (account["userRateLimitTier"] as? String) ?? (account["organizationRateLimitTier"] as? String)
        return (account["emailAddress"] as? String, tier)
    }

    // MARK: Parsing

    /// "default_claude_max_20x" → "Max 20x"; "pro" → "Pro".
    static func planName(subscriptionType: String?, rateLimitTier: String?) -> String? {
        let tier = rateLimitTier?.lowercased() ?? ""
        if let range = tier.range(of: #"max_?(\d+)x"#, options: .regularExpression) {
            let digits = tier[range].filter(\.isNumber)
            return "Max \(digits)x"
        }
        guard let type = subscriptionType?.lowercased(), !type.isEmpty else { return nil }
        return Fmt.planName(type)
    }

    static func snapshot(from usage: JSONValue, plan: String?, account: String?, now: Date = Date()) -> ProviderSnapshot {
        var windows: [UsageWindow] = []
        var facts: [Fact] = []
        let object = usage.object ?? [:]
        Log.debug("claude: usage keys \(object.keys.sorted().map { key in "\(key)\(object[key]?["utilization"]?.double == nil ? "" : "*")" })")

        for key in object.keys.sorted(by: sortOrder) {
            guard let value = object[key], value["utilization"] != nil,
                  let used = value["utilization"]?.double else { continue }
            let resetsAt = DateParsing.date(value["resets_at"])
            if key == "extra_usage" { continue }
            let (label, kind, duration) = describe(key)
            windows.append(UsageWindow(id: key, label: label, kind: kind, usedPercent: used,
                                       resetsAt: resetsAt, duration: duration))
        }

        if let extra = object["extra_usage"], extra["is_enabled"]?.bool == true {
            if let used = extra["utilization"]?.double {
                facts.append(Fact("Uso extra", "\(Fmt.percent(used)) del límite mensual", symbol: "creditcard"))
            } else {
                facts.append(Fact("Uso extra", "activado", symbol: "creditcard"))
            }
        }

        return ProviderSnapshot(provider: .claude, plan: plan, account: account, windows: windows,
                                facts: facts, fetchedAt: now)
    }

    private static func sortOrder(_ a: String, _ b: String) -> Bool {
        func rank(_ key: String) -> Int {
            switch key {
            case "five_hour": 0
            case "seven_day": 1
            case "seven_day_opus": 2
            case "seven_day_sonnet": 3
            default: key.hasPrefix("five_hour") ? 4 : 5
            }
        }
        return (rank(a), a) < (rank(b), b)
    }

    private static func describe(_ key: String) -> (String, WindowKind, TimeInterval?) {
        let fiveHours: TimeInterval = 5 * 3600
        let week: TimeInterval = 7 * 86_400
        switch key {
        case "five_hour": return ("Sesión · 5 h", .session, fiveHours)
        case "seven_day": return ("Semana", .weekly, week)
        case "seven_day_opus": return ("Semana · Opus", .weeklyModel, week)
        case "seven_day_sonnet": return ("Semana · Sonnet", .weeklyModel, week)
        case "seven_day_oauth_apps": return ("Semana · apps conectadas", .weeklyModel, week)
        default:
            if key.hasPrefix("seven_day_") {
                return ("Semana · \(humanize(String(key.dropFirst("seven_day_".count))))", .weeklyModel, week)
            }
            if key.hasPrefix("five_hour_") {
                return ("5 h · \(humanize(String(key.dropFirst("five_hour_".count))))", .other, fiveHours)
            }
            return (humanize(key), .other, nil)
        }
    }

    private static func humanize(_ key: String) -> String {
        let words = key.split(separator: "_").map(String.init)
        guard let first = words.first else { return key }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }
}

extension Data {
    init?(hexString: String) {
        let characters = Array(hexString.utf8)
        guard characters.count.isMultiple(of: 2), !characters.isEmpty else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let byte = UInt8(String(decoding: characters[index...index + 1], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(byte)
            index += 2
        }
        self.init(bytes)
    }
}
