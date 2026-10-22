import Foundation
import ServiceManagement
import TokenAnxietyCore
import UserNotifications

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
        let window = UsageWindow(id: "test", label: "Semana", kind: .weekly, usedPercent: 80,
                                 resetsAt: Date().addingTimeInterval(2 * 86_400))
        post([AlertTracker.Event(provider: .claude, window: window, kind: .threshold(80),
                                 title: "Token Anxiety: así se ven los avisos",
                                 body: "Empieza la ansiedad. Se renueva \(Fmt.moment(window.resetsAt!)).")])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// "Abrir al iniciar sesión", through the system's login items.
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
