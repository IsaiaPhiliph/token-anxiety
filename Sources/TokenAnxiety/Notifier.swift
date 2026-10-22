import AppKit
import ServiceManagement
import TokenAnxietyCore
import UserNotifications

/// What macOS lets the app's notifications do.
enum NotificationAccess {
    case allowed
    /// Allowed without "Desktop" (alert style none): they only reach Notification Center.
    case quiet
    case denied
    case notAsked
    /// `swift run`, without a bundle.
    case unavailable
}

/// Posts the alert tracker's events as macOS notifications.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// UserNotifications needs a bundle; `swift run` has none.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func setUp() {
        guard let center else { return }
        center.delegate = self
    }

    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func access() async -> NotificationAccess {
        guard let center else { return .unavailable }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notAsked
        case .denied: return .denied
        default:
            let onScreen = settings.alertStyle != UNAlertStyle.none && settings.alertSetting != .disabled
            return onScreen ? .allowed : .quiet
        }
    }

    /// Shows macOS's permission prompt if it was never answered.
    func requestAccess() async -> NotificationAccess {
        _ = try? await center?.requestAuthorization(options: [.alert, .sound])
        return await access()
    }

    /// System Settings › Notifications › Token Anxiety.
    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    func post(_ events: [AlertTracker.Event]) {
        guard let center, !events.isEmpty else { return }
        requestAuthorization()
        for event in events {
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body
            content.sound = event.kind == .exhausted ? .defaultCritical : .default
            content.threadIdentifier = event.provider.rawValue
            let request = UNNotificationRequest(identifier: "\(event.provider.rawValue).\(event.window.id).\(UUID().uuidString)",
                                                content: content, trigger: nil)
            center.add(request)
        }
    }

    func sendTest() {
        let window = UsageWindow(id: "test", label: String(localized: "Week"), kind: .weekly, usedPercent: 80,
                                 resetsAt: Date().addingTimeInterval(2 * 86_400))
        post([AlertTracker.Event(provider: .claude, window: window, kind: .threshold(80),
                                 title: String(localized: "Token Anxiety: this is what alerts look like"),
                                 body: String(localized: "The anxiety begins.") + " " + String(localized: "Resets \(Fmt.moment(window.resetsAt!))."))])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// "Open at login", through the system's login items.
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// The first launch from /Applications turns it on, since the user asked for it;
    /// builds run from elsewhere are left alone.
    static func enableOnFirstLaunchFromApplications() {
        let key = "loginItemConfigured"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let path = Bundle.main.bundlePath
        guard path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/") else { return }
        UserDefaults.standard.set(true, forKey: key)
        if status != .enabled { try? set(true) }
    }
}
