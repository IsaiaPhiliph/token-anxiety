import AppKit
import Observation
import TokenAnxietyCore

/// Owns the menu bar item: redraws it whenever the store or the settings
/// change, opens the panel on click and a small menu on right click.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store: UsageStore
    private let settings: AppSettings
    private let panel: PanelController
    private let openSettings: () -> Void
    private var appearanceObservation: NSKeyValueObservation?
    private var lastRender: ([MenuBarRenderer.Item], MenuBarRenderer.Options)?

    init(store: UsageStore, settings: AppSettings, panel: PanelController, openSettings: @escaping () -> Void) {
        self.store = store
        self.settings = settings
        self.panel = panel
        self.openSettings = openSettings
        super.init()

        statusItem.autosaveName = "TokenAnxiety"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in self?.render() }
            }
        }
        observe()
    }

    var button: NSStatusBarButton? { statusItem.button }

    /// Re-renders on every change of what `render()` reads.
    private func observe() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let now = Date()
        let items = store.menuBarProviders.map { id -> MenuBarRenderer.Item in
            let snapshot = store.entries[id]?.snapshot
            return MenuBarRenderer.Item(provider: id, primary: snapshot?.primary?.usedPercent,
                                        secondary: snapshot?.secondary?.usedPercent,
                                        dimmed: store.isStale(id, now: now))
        }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let options = MenuBarRenderer.Options(style: settings.menuStyle, colorize: settings.colorizeMenuBar,
                                              warn: Double(settings.warnThreshold),
                                              critical: Double(settings.criticalThreshold), dark: dark)
        if let lastRender, lastRender.0 == items, lastRender.1 == options { return }
        lastRender = (items, options)
        button.image = MenuBarRenderer.image(items: items, options: options)
        button.toolTip = tooltip(for: items)
        button.setAccessibilityLabel(button.toolTip)
    }

    private func tooltip(for items: [MenuBarRenderer.Item]) -> String {
        guard !items.isEmpty else { return String(localized: "Token Anxiety: no plans found") }
        return items.map { item in
            let figures = [item.primary.map { "5 h \(Fmt.percent($0))" }, item.secondary.map { String(localized: "week \(Fmt.percent($0))") }]
                .compactMap { $0 }.joined(separator: ", ")
            return "\(item.provider.displayName): \(figures.isEmpty ? String(localized: "no data") : figures)"
        }.joined(separator: "\n")
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu(from: sender)
        } else {
            panel.toggle(below: sender)
        }
    }

    private func showMenu(from button: NSStatusBarButton) {
        panel.close()
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Refresh now"), action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Token Anxiety"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
    }

    @objc private func refreshNow() {
        Task { await store.refresh(manual: true) }
    }

    @objc private func showSettings() {
        openSettings()
    }
}
