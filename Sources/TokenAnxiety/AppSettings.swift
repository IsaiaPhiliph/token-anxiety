import Foundation
import Observation
import TokenAnxietyCore

enum MenuStyle: String, CaseIterable, Identifiable {
    case percentages
    case bars
    case numberAndBar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .percentages: String(localized: "Percentages")
        case .bars: String(localized: "Double bars")
        case .numberAndBar: String(localized: "Figure + bar")
        }
    }
}

/// User preferences, stored in UserDefaults.
@MainActor @Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    var menuStyle: MenuStyle { didSet { defaults.set(menuStyle.rawValue, forKey: "menuStyle") } }
    var colorizeMenuBar: Bool { didSet { defaults.set(colorizeMenuBar, forKey: "colorizeMenuBar") } }
    var refreshMinutes: Int { didSet { defaults.set(refreshMinutes, forKey: "refreshMinutes") } }
    var showPace: Bool { didSet { defaults.set(showPace, forKey: "showPace") } }
    var showAccounts: Bool { didSet { defaults.set(showAccounts, forKey: "showAccounts") } }
    var historyEnabled: Bool { didSet { defaults.set(historyEnabled, forKey: "historyEnabled") } }
    var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled") } }
    var warnThreshold: Int { didSet { defaults.set(warnThreshold, forKey: "warnThreshold") } }
    var criticalThreshold: Int { didSet { defaults.set(criticalThreshold, forKey: "criticalThreshold") } }
    var notifyRenewals: Bool { didSet { defaults.set(notifyRenewals, forKey: "notifyRenewals") } }
    /// Read by `ClaudeProvider` itself, which renews Claude Code's session when it expires.
    var renewClaudeSession: Bool { didSet { defaults.set(renewClaudeSession, forKey: ClaudeProvider.renewalDefaultsKey) } }
    /// Services the user switched off entirely.
    private var disabled: Set<String> { didSet { defaults.set(Array(disabled), forKey: "disabledProviders") } }
    /// Services that stay in the panel but out of the menu bar.
    private var hiddenInMenuBar: Set<String> { didSet { defaults.set(Array(hiddenInMenuBar), forKey: "hiddenInMenuBar") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "menuStyle": MenuStyle.percentages.rawValue,
            "colorizeMenuBar": true,
            "refreshMinutes": 2,
            "showPace": true,
            "showAccounts": true,
            "historyEnabled": true,
            "notificationsEnabled": true,
            "warnThreshold": 80,
            "criticalThreshold": 95,
            "notifyRenewals": true,
            ClaudeProvider.renewalDefaultsKey: true,
            "disabledProviders": [String](),
            // Cursor only has a monthly figure, so it starts in the panel only.
            "hiddenInMenuBar": [ProviderID.cursor.rawValue],
        ])
        menuStyle = MenuStyle(rawValue: defaults.string(forKey: "menuStyle") ?? "") ?? .percentages
        colorizeMenuBar = defaults.bool(forKey: "colorizeMenuBar")
        refreshMinutes = max(1, defaults.integer(forKey: "refreshMinutes"))
        showPace = defaults.bool(forKey: "showPace")
        showAccounts = defaults.bool(forKey: "showAccounts")
        historyEnabled = defaults.bool(forKey: "historyEnabled")
        notificationsEnabled = defaults.bool(forKey: "notificationsEnabled")
        warnThreshold = defaults.integer(forKey: "warnThreshold")
        criticalThreshold = defaults.integer(forKey: "criticalThreshold")
        notifyRenewals = defaults.bool(forKey: "notifyRenewals")
        renewClaudeSession = defaults.bool(forKey: ClaudeProvider.renewalDefaultsKey)
        disabled = Set(defaults.stringArray(forKey: "disabledProviders") ?? [])
        hiddenInMenuBar = Set(defaults.stringArray(forKey: "hiddenInMenuBar") ?? [])
    }

    func isEnabled(_ id: ProviderID) -> Bool { !disabled.contains(id.rawValue) }

    func setEnabled(_ id: ProviderID, _ enabled: Bool) {
        if enabled { disabled.remove(id.rawValue) } else { disabled.insert(id.rawValue) }
    }

    func showsInMenuBar(_ id: ProviderID) -> Bool { !hiddenInMenuBar.contains(id.rawValue) }

    func setShowsInMenuBar(_ id: ProviderID, _ shown: Bool) {
        if shown { hiddenInMenuBar.remove(id.rawValue) } else { hiddenInMenuBar.insert(id.rawValue) }
    }

    var thresholds: [Int] { [warnThreshold, criticalThreshold] }

    /// Colour band of a figure: calm, then warning and critical from the alert thresholds.
    func level(_ percent: Double) -> UsageLevel {
        if percent >= Double(criticalThreshold) { return .critical }
        if percent >= Double(warnThreshold) { return .warning }
        if percent >= 50 { return .moderate }
        return .calm
    }
}

enum UsageLevel: Int, Comparable {
    case calm, moderate, warning, critical

    static func < (lhs: UsageLevel, rhs: UsageLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}
