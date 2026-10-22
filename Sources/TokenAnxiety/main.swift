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
    private var stats: StatsWindowController?

    private let arguments = CommandLine.arguments

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = AppSettings()
        notifier = Notifier()
        notifier.setUp()
        store = UsageStore(settings: settings, notifier: notifier, demo: arguments.contains("--demo"))
        panel = PanelController(store: store, settings: settings, openSettings: { [weak self] in self?.showSettings() },
                                openStats: { [weak self] in self?.showStats() })
        statusItem = StatusItemController(store: store, settings: settings, panel: panel,
                                          openSettings: { [weak self] in self?.showSettings() },
                                          openStats: { [weak self] in self?.showStats() })
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
        if let index = arguments.firstIndex(of: "--open-stats") {
            // An optional section to start on, for screenshots: `--open-stats hours`.
            let section = arguments.indices.contains(index + 1) ? StatsSection(rawValue: arguments[index + 1]) : nil
            showStats(section: section)
        }
    }

    func showStats(section: StatsSection? = nil) {
        if stats == nil { stats = StatsWindowController(store: store) }
        stats?.show(section: section)
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
/// `--print --stats [--days N]` reads the local logs instead and prints what they add up to.
enum Doctor {
    static func run() async {
        if CommandLine.arguments.contains("--stats") { return await stats() }
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

extension Doctor {
    /// Totals per day, project and model from Claude Code's and Codex's logs, read from
    /// scratch into memory (the app's own ledger is left alone; `--store DIR` keeps one
    /// there instead, to time later reads). Project names only, no paths.
    static func stats() async {
        let arguments = CommandLine.arguments
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        let days = value("--days").flatMap(Int.init) ?? 7
        let indexer = LedgerIndexer(directory: value("--store").map { URL(fileURLWithPath: $0) })
        let started = Date()
        let ledger = await indexer.update()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today)!
        let interval = DateInterval(start: start, end: Date())
        print("== Local usage, last \(days) days (read in \(String(format: "%.1f", Date().timeIntervalSince(started))) s, history since \(ledger.firstDate.map { Fmt.day($0) } ?? "–"))")
        if indexer.compressedFilesSkipped > 0 { print("   \(indexer.compressedFilesSkipped) compressed Codex logs skipped") }

        func line(_ totals: UsageTotals) -> String {
            let c = totals.counts
            var text = "in=\(c.input) out=\(c.output) cw=\(c.cacheWrite) cr=\(c.cacheRead) req=\(c.requests) ≈\(String(format: "$%.2f", totals.cost))"
            if totals.unpricedTokens > 0 { text += " (+\(Fmt.tokens(Double(totals.unpricedTokens))) unpriced)" }
            return text
        }
        for provider in [ProviderID.claude, .codex] {
            let total = ledger.totals(in: interval, provider: provider)
            guard total.counts.requests > 0 else { continue }
            print("-- \(provider.displayName): \(Fmt.tokens(Double(total.counts.total))) tokens, \(line(total))")
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            for (day, totals) in ledger.daily(in: interval, provider: provider).sorted(by: { $0.key < $1.key }) {
                print("   \(formatter.string(from: day))  \(line(totals))")
            }
            print("   projects:")
            for (project, totals) in ledger.grouped(in: interval, provider: provider, by: \.project)
                .sorted(by: { $0.value.counts.total > $1.value.counts.total }).prefix(10) {
                print("     \(project): \(Fmt.tokens(Double(totals.counts.total))) ≈\(String(format: "$%.2f", totals.cost))")
            }
            print("   models:")
            for (model, totals) in ledger.grouped(in: interval, provider: provider, by: { ModelNames.display($0.model) })
                .sorted(by: { $0.value.counts.total > $1.value.counts.total }) {
                print("     \(model): \(Fmt.tokens(Double(totals.counts.total))) ≈\(String(format: "$%.2f", totals.cost))")
            }
            let sessions = ledger.sessions(in: interval, provider: provider)
            print("   sessions: \(sessions.count), with subagents: \(sessions.filter { !$0.agents.isEmpty }.count), titled: \(sessions.filter { ledger.title(of: $0) != nil }.count)")
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
