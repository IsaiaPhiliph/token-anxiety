import Foundation
import SQLite3

/// Cursor's monthly plan usage. Cursor has no five-hour or weekly window, only
/// the billing cycle, so it lives in the panel and stays out of the menu bar
/// unless the user turns it on.
///
/// The session is the one the Cursor app keeps in its local state database;
/// it is sent only to cursor.com, as the dashboard does.
public actor CursorProvider: UsageProvider {
    public nonisolated let id = ProviderID.cursor

    private let home: URL
    private let session: URLSession

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, session: URLSession = .shared) {
        self.home = home
        self.session = session
    }

    private var database: URL {
        home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    public func isInstalled() async -> Bool {
        FileManager.default.isFile(database)
    }

    public func fetch() async throws -> ProviderSnapshot {
        let values = SQLiteKeyValue.read(database, keys: [
            "cursorAuth/accessToken", "cursorAuth/cachedEmail", "cursorAuth/stripeMembershipType",
        ])
        Log.debug("cursor: database \(FileManager.default.isFile(database) ? "found" : "missing"), keys \(values.keys.sorted())")
        guard let token = values["cursorAuth/accessToken"], !token.isEmpty,
              let subject = JWT.claims(token)?["sub"]?.string else {
            throw ProviderError.notLoggedIn(String(localized: "Sign in to Cursor to see your usage."))
        }
        let userID = subject.split(separator: "|").last.map(String.init) ?? subject
        let cookie = "WorkosCursorSessionToken=\(userID)%3A%3A\(token)"
        let email = values["cursorAuth/cachedEmail"]
        let membership = values["cursorAuth/stripeMembershipType"]

        do {
            let request = HTTP.request(URL(string: "https://cursor.com/api/usage-summary")!, headers: ["Cookie": cookie])
            let summary = try await HTTP.json(request, session: session)
            if let snapshot = Self.snapshot(summary: summary, membership: membership, email: email) {
                return snapshot
            }
        } catch ProviderError.http(let status) where status == 401 || status == 403 {
            throw ProviderError.sessionExpired(String(localized: "Cursor's session has expired. Open Cursor to renew it."))
        } catch ProviderError.http(404) {
            // Older accounts: fall through to the request-based endpoint.
        }

        let legacy = HTTP.request(URL(string: "https://cursor.com/api/usage?user=\(userID)")!, headers: ["Cookie": cookie])
        let usage = try await HTTP.json(legacy, session: session)
        return Self.snapshot(legacy: usage, membership: membership, email: email)
    }

    // MARK: Parsing

    /// `/api/usage-summary`: amounts in cents, a billing cycle, and pools for
    /// "Auto" and named-model ("API") usage.
    static func snapshot(summary: JSONValue, membership: String?, email: String?, now: Date = Date()) -> ProviderSnapshot? {
        guard let usage = summary["individualUsage"] ?? summary["teamUsage"] else { return nil }
        let start = DateParsing.date(summary["billingCycleStart"])
        let end = DateParsing.date(summary["billingCycleEnd"])
        let duration = (start != nil && end != nil) ? end!.timeIntervalSince(start!) : 30 * 86_400
        var windows: [UsageWindow] = []
        var facts: [Fact] = []

        if let plan = usage["plan"], plan["enabled"]?.bool != false {
            let used = plan["used"]?.double ?? plan["breakdown"]?["total"]?.double
            let limit = plan["limit"]?.double
            var percent = plan["totalPercentUsed"]?.double
            if percent == nil, let used, let limit, limit > 0 { percent = used / limit * 100 }
            if let percent {
                let detail = (used != nil && (limit ?? 0) > 0) ? String(localized: "\(Fmt.money(used! / 100)) of \(Fmt.money(limit! / 100))") : nil
                windows.append(UsageWindow(id: "plan", label: String(localized: "This month"), kind: .monthly, usedPercent: percent,
                                           resetsAt: end, duration: duration, detail: detail))
            }
            if let auto = plan["autoPercentUsed"]?.double {
                windows.append(UsageWindow(id: "auto", label: String(localized: "Auto and Composer"), kind: .other, usedPercent: auto,
                                           resetsAt: end, duration: duration))
            }
            if let api = plan["apiPercentUsed"]?.double {
                windows.append(UsageWindow(id: "api", label: String(localized: "Selected models"), kind: .other, usedPercent: api,
                                           resetsAt: end, duration: duration))
            }
        }
        if let onDemand = usage["onDemand"], onDemand["enabled"]?.bool == true {
            let used = onDemand["used"]?.double ?? 0
            if let limit = onDemand["limit"]?.double, limit > 0 {
                facts.append(Fact(String(localized: "On-demand"), String(localized: "\(Fmt.money(used / 100)) of \(Fmt.money(limit / 100))"), symbol: "creditcard"))
            } else {
                facts.append(Fact(String(localized: "On-demand"), Fmt.money(used / 100), symbol: "creditcard"))
            }
        }
        if summary["isUnlimited"]?.bool == true {
            facts.append(Fact(String(localized: "Plan"), String(localized: "unlimited"), symbol: "infinity"))
        }
        guard !windows.isEmpty || !facts.isEmpty else { return nil }
        let plan = (summary["membershipType"]?.string ?? membership).map(Fmt.planName)
        return ProviderSnapshot(provider: .cursor, plan: plan, account: email, windows: windows, facts: facts, fetchedAt: now)
    }

    /// `/api/usage?user=…`: request counts per model and the start of the month.
    static func snapshot(legacy usage: JSONValue, membership: String?, email: String?, now: Date = Date()) -> ProviderSnapshot {
        var windows: [UsageWindow] = []
        let start = DateParsing.date(usage["startOfMonth"])
        let end = start.flatMap { Calendar.current.date(byAdding: .month, value: 1, to: $0) }
        // Fast requests ("gpt-4") are the plan's figure; the other models follow by name.
        func rank(_ model: String) -> (Int, String) { (model == "gpt-4" ? 0 : 1, model) }
        for (model, value) in (usage.object ?? [:]).sorted(by: { rank($0.key) < rank($1.key) }) {
            guard let requests = value["numRequests"]?.double, let max = value["maxRequestUsage"]?.double, max > 0 else { continue }
            windows.append(UsageWindow(id: model, label: model == "gpt-4" ? String(localized: "Fast requests") : model,
                                       kind: windows.isEmpty ? .monthly : .other, usedPercent: requests / max * 100,
                                       resetsAt: end, duration: 30 * 86_400,
                                       detail: String(localized: "\(Int(requests)) of \(Int(max)) requests")))
        }
        return ProviderSnapshot(provider: .cursor, plan: membership.map(Fmt.planName), account: email,
                                windows: windows, fetchedAt: now)
    }
}

/// Read-only lookups in a VS Code-style `state.vscdb` (table `ItemTable`).
enum SQLiteKeyValue {
    static func read(_ url: URL, keys: [String]) -> [String: String] {
        guard let db = open(url) else { return [:] }
        defer { sqlite3_close(db) }
        var values: [String: String] = [:]
        for key in keys {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?1", -1, &statement, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(statement) == SQLITE_ROW else { continue }
            let length = Int(sqlite3_column_bytes(statement, 0))
            if let bytes = sqlite3_column_blob(statement, 0), length > 0 {
                var text = String(decoding: Data(bytes: bytes, count: length), as: UTF8.self)
                // Some values are stored as JSON strings.
                if text.hasPrefix("\""), text.hasSuffix("\""), let decoded = try? JSONValue.parse(Data(text.utf8)).string {
                    text = decoded
                }
                values[key] = text
            }
        }
        return values
    }

    /// Opens read-only. A WAL database whose app is closed has no -wal/-shm files,
    /// which a read-only connection cannot create; it is then read as immutable,
    /// which is exact because nothing is writing to it.
    private static func open(_ url: URL) -> OpaquePointer? {
        let path = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        for options in ["mode=ro", "mode=ro&immutable=1"] {
            var db: OpaquePointer?
            if sqlite3_open_v2("file:\(path)?\(options)", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK {
                sqlite3_busy_timeout(db, 1500)
                // Opening is lazy: a first query tells whether the file can really be read.
                let check = sqlite3_exec(db, "SELECT 1 FROM ItemTable LIMIT 1", nil, nil, nil)
                Log.debug("sqlite: \(url.lastPathComponent) with \(options) → \(check)")
                if check == SQLITE_OK { return db }
            }
            sqlite3_close(db)
        }
        return nil
    }
}
