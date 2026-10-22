import AppKit
import SwiftUI
import TokenAnxietyCore

/// What the panel's buttons do.
@MainActor
struct PanelActions {
    var refresh: () -> Void
    var openSettings: () -> Void
    var quit: () -> Void
    var resize: (CGFloat) -> Void
}

/// The details panel under the menu bar item: a borderless Liquid Glass panel
/// that closes on any click outside it or on Escape.
@MainActor
final class PanelController {
    static let width: CGFloat = 372
    static let cornerRadius: CGFloat = 26

    private let store: UsageStore
    private let settings: AppSettings
    private let openSettings: () -> Void
    private var panel: GlassPanel?
    private var contentHeight: CGFloat = 420
    private weak var anchor: NSStatusBarButton?
    private var monitors: [Any] = []
    private var shownAt = Date.distantPast

    init(store: UsageStore, settings: AppSettings, openSettings: @escaping () -> Void) {
        self.store = store
        self.settings = settings
        self.openSettings = openSettings
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle(below button: NSStatusBarButton) {
        if isVisible { close() } else { show(below: button) }
    }

    func show(below button: NSStatusBarButton) {
        anchor = button
        let panel = self.panel ?? makePanel()
        self.panel = panel
        place(panel)
        shownAt = Date()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
        button.highlight(true)
        installMonitors()
        store.refreshIfStale()
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        removeMonitors()
        anchor?.highlight(false)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in panel.orderOut(nil) }
        }
    }

    private func makePanel() -> GlassPanel {
        let panel = GlassPanel()
        let actions = PanelActions(
            refresh: { [weak self] in
                guard let self else { return }
                Task { await self.store.refresh(manual: true) }
            },
            openSettings: { [weak self] in
                self?.close()
                self?.openSettings()
            },
            quit: { NSApp.terminate(nil) },
            resize: { [weak self] height in self?.contentHeightChanged(height) }
        )
        let root = PanelView(store: store, settings: settings, actions: actions)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        let glass = NSGlassEffectView()
        glass.cornerRadius = Self.cornerRadius
        glass.contentView = hosting
        // The glass leaves a faint fill in its square corners, and the window's shadow
        // follows whatever is drawn: clipped to the rounded shape, so is the shadow.
        let clip = NSView()
        clip.wantsLayer = true
        clip.layer?.cornerRadius = Self.cornerRadius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        glass.autoresizingMask = [.width, .height]
        clip.addSubview(glass)
        panel.contentView = clip
        return panel
    }

    private var maxHeight: CGFloat {
        let screen = anchor?.window?.screen ?? NSScreen.main
        return (screen?.visibleFrame.height ?? 800) - 24
    }

    private func contentHeightChanged(_ height: CGFloat) {
        guard abs(height - contentHeight) > 0.5 else { return }
        // Growing animates (a chart opening), except while the panel is appearing.
        let animate = height > contentHeight && Date().timeIntervalSince(shownAt) > 0.4
        contentHeight = height
        // SwiftUI reports the first height while the panel is still being ordered
        // in, and frames cannot change in the middle of its layout pass.
        Task { @MainActor in
            guard let panel = self.panel, panel.isVisible else { return }
            self.place(panel, animated: animate)
        }
    }

    /// Centred under the menu bar item, kept on screen, growing downwards.
    private func place(_ panel: GlassPanel, animated: Bool = false) {
        guard let button = anchor, let window = button.window else { return }
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let height = min(contentHeight, maxHeight)
        var x = buttonFrame.midX - Self.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - Self.width - 8)
        let top = min(buttonFrame.minY - 6, visible.maxY - 4)
        let frame = NSRect(x: x, y: top - height, width: Self.width, height: height)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func installMonitors() {
        removeMonitors()
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            if event.keyCode == 53 { // Escape
                MainActor.assumeIsolated { self?.close() }
                return nil
            }
            return event
        }) {
            monitors.append(monitor)
        }
    }

    private func removeMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }
}

final class GlassPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: PanelController.width, height: 420),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
