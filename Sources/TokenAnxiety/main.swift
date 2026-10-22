import AppKit
import SwiftUI
import TokenAnxietyCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings!
    private var notifier: Notifier!
    private var store: UsageStore!
    private var panel: PanelController!
    private var statusItem: StatusItemController!
    private var settingsWindow: NSWindow?

    private let arguments = CommandLine.arguments

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = AppSettings()
        notifier = Notifier()
        notifier.setUp()
        store = UsageStore(settings: settings, notifier: notifier, demo: arguments.contains("--demo"))
        panel = PanelController(store: store, settings: settings) { [weak self] in self?.showSettings() }
        statusItem = StatusItemController(store: store, settings: settings, panel: panel) { [weak self] in self?.showSettings() }
        store.start()
        if settings.notificationsEnabled { notifier.requestAuthorization() }
        LoginItem.enableOnFirstLaunchFromApplications()

        if arguments.contains("--open-panel") {
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                if let button = statusItem.button { panel.show(below: button) }
            }
        }
        if arguments.contains("--open-settings") { showSettings() }
    }

    func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: settings, store: store, notifier: notifier)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = String(localized: "Token Anxiety Settings")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("Settings")
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

/// `--print`: asks every service once and prints the figures (never tokens or
/// emails), to check detection from a terminal. `--only codex,cursor` limits it.
enum Doctor {
    static func run() async {
        var providers: [any UsageProvider] = [ClaudeProvider(), CodexProvider(), AntigravityProvider(), CursorProvider()]
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--only"), index + 1 < arguments.count {
            let wanted = arguments[index + 1].split(separator: ",").map(String.init)
            providers.removeAll { !wanted.contains($0.id.rawValue) }
        }
        for provider in providers {
            let installed = await provider.isInstalled()
            print("== \(provider.id.displayName): \(installed ? "found" : "not found")")
            guard installed else { continue }
            let start = Date()
            defer { Log.debug("\(provider.id.rawValue): \(String(format: "%.1f", Date().timeIntervalSince(start))) s") }
            do {
                let snapshot = try await provider.fetch()
                print("   plan: \(snapshot.plan ?? "–")")
                for window in snapshot.windows {
                    print("   \(window.label) [\(window.kind.rawValue)]: \(Fmt.percent(window.usedPercent)) · \(Fmt.resetLine(window.resetsAt) ?? "no date")")
                }
                for fact in snapshot.facts { print("   \(fact.label): \(fact.value)") }
                if !snapshot.dailyTokens.isEmpty { print("   tokens per day: \(snapshot.dailyTokens.count) days") }
            } catch {
                print("   error: \(error.localizedDescription)")
            }
        }
    }
}

if CommandLine.arguments.contains("--print") {
    Task.detached {
        await Doctor.run()
        exit(0)
    }
    dispatchMain()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
