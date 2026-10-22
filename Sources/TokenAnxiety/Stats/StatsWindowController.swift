import AppKit
import SwiftUI

/// The Statistics window: a regular window, opened from the panel or the right-click menu.
@MainActor
final class StatsWindowController {
    private let store: UsageStore
    private let navigation = StatsNavigation()
    private var window: NSWindow?

    init(store: UsageStore) {
        self.store = store
    }

    func show(section: StatsSection? = nil) {
        if let section { navigation.section = section }
        if window == nil {
            let view = StatsView(store: store, usage: store.usage, navigation: navigation)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = String(localized: "Statistics")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 980, height: 700))
            window.contentMinSize = NSSize(width: 820, height: 560)
            window.setFrameAutosaveName("Statistics")
            if window.frame.origin == .zero { window.center() }
            self.window = window
        }
        // Newly appended lines show up as soon as the window opens.
        store.usage.update()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
