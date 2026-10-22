import Foundation

public enum ProviderID: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude
    case codex
    case antigravity
    case cursor

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        case .cursor: "Cursor"
        }
    }

    /// The desktop app whose icon the panel shows, if it is installed.
    public var appBundleIdentifiers: [String] {
        switch self {
        case .claude: ["com.anthropic.claudefordesktop"]
        case .codex: ["com.openai.codex", "com.openai.chat"]
        case .antigravity: ["com.google.antigravity"]
        case .cursor: ["com.todesktop.230313mzl4w4u92"]
        }
    }

    public var appNames: [String] {
        switch self {
        case .claude: ["Claude"]
        case .codex: ["Codex", "ChatGPT"]
        case .antigravity: ["Antigravity", "Antigravity IDE"]
        case .cursor: ["Cursor"]
        }
    }
}

public enum WindowKind: String, Codable, Sendable {
    /// The rolling five-hour window.
    case session
    /// The seven-day window that covers every model.
    case weekly
    /// A seven-day sub-limit for one model family (Opus, Sonnet…).
    case weeklyModel
    /// A billing cycle (Cursor).
    case monthly
    /// A per-model quota (Antigravity).
    case model
    case other
}

public struct UsageWindow: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var kind: WindowKind
    /// 0…100, and can go over 100 when a service lets you overrun.
    public var usedPercent: Double
    public var resetsAt: Date?
    /// Length of the window, which pace needs to know where it started.
    public var duration: TimeInterval?
    /// A second line for the panel, e.g. "12,40 US$ de 20 US$".
    public var detail: String?

    public init(id: String, label: String, kind: WindowKind, usedPercent: Double,
                resetsAt: Date? = nil, duration: TimeInterval? = nil, detail: String? = nil) {
        self.id = id
        self.label = label
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.duration = duration
        self.detail = detail
    }
}

/// A label/value line shown under a provider's meters ("Extra usage", "Streak"…).
public struct Fact: Codable, Sendable, Hashable, Identifiable {
    public var label: String
    public var value: String
    public var symbol: String?
    public var id: String { label }

    public init(_ label: String, _ value: String, symbol: String? = nil) {
        self.label = label
        self.value = value
        self.symbol = symbol
    }
}

public struct DayValue: Codable, Sendable, Hashable {
    public var day: Date
    public var value: Double

    public init(day: Date, value: Double) {
        self.day = day
        self.value = value
    }
}

public struct ProviderSnapshot: Codable, Sendable, Hashable {
    public var provider: ProviderID
    public var plan: String?
    public var account: String?
    public var windows: [UsageWindow]
    public var facts: [Fact]
    /// Tokens per day, when the service reports them (Codex).
    public var dailyTokens: [DayValue]
    public var fetchedAt: Date

    public init(provider: ProviderID, plan: String? = nil, account: String? = nil,
                windows: [UsageWindow], facts: [Fact] = [], dailyTokens: [DayValue] = [],
                fetchedAt: Date = Date()) {
        self.provider = provider
        self.plan = plan
        self.account = account
        self.windows = windows
        self.facts = facts
        self.dailyTokens = dailyTokens
        self.fetchedAt = fetchedAt
    }

    /// The figure the menu bar shows first: the five-hour window, or the most
    /// used per-model quota for services that only have those.
    public var primary: UsageWindow? {
        if let session = windows.first(where: { $0.kind == .session }) { return session }
        if let model = windows.filter({ $0.kind == .model && !isLong($0) }).max(by: { $0.usedPercent < $1.usedPercent }) {
            return model
        }
        return windows.first { $0.kind == .monthly }
    }

    /// The second figure: the week (or the most used long per-model quota).
    public var secondary: UsageWindow? {
        if let weekly = windows.first(where: { $0.kind == .weekly }) { return weekly }
        return windows.filter { $0.kind == .model && isLong($0) }.max { $0.usedPercent < $1.usedPercent }
    }

    /// The windows that are not the two headline ones.
    public var otherWindows: [UsageWindow] {
        let headline = Set([primary?.id, secondary?.id].compactMap { $0 })
        return windows.filter { !headline.contains($0.id) }
    }

    /// Per-model quotas whose window is longer than a day count as weekly.
    private func isLong(_ window: UsageWindow) -> Bool {
        (window.duration ?? 0) > 86_400
    }
}

public enum ProviderError: Error, LocalizedError, Sendable, Equatable {
    /// Nothing from this service on the Mac.
    case notInstalled
    /// Installed, but signed out.
    case notLoggedIn(String)
    /// The saved session expired and the service's own app has to renew it.
    case sessionExpired(String)
    /// macOS refused access (Keychain). Not retried until the user asks.
    case accessDenied(String)
    /// The service only answers while its app is open (Antigravity).
    case notRunning(String)
    case http(Int)
    /// 429: ask again after `retryAfter` seconds, the service's `Retry-After` when it sends one.
    case rateLimited(retryAfter: TimeInterval?)
    case network(String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: String(localized: "Not installed on this Mac.")
        case .notLoggedIn(let message), .sessionExpired(let message), .accessDenied(let message),
             .notRunning(let message), .network(let message), .badResponse(let message):
            message
        case .rateLimited:
            String(localized: "Too many requests in a row; trying again in a while.")
        case .http(let status):
            switch status {
            case 401, 403: String(localized: "The service rejected the session (\(status)).")
            case 429: ProviderError.rateLimited(retryAfter: nil).errorDescription ?? ""
            case 500...: String(localized: "The service is not answering right now (\(status)).")
            default: String(localized: "Unexpected answer from the service (\(status)).")
            }
        }
    }

    /// Errors that need the user, not another automatic retry.
    public var needsUser: Bool {
        switch self {
        case .notLoggedIn, .sessionExpired, .accessDenied: true
        default: false
        }
    }
}

public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    /// A quick local check (files, apps) that decides whether the service shows up at all.
    func isInstalled() async -> Bool
    func fetch() async throws -> ProviderSnapshot
}
