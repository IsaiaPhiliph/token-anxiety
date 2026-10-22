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

    func show(section: StatsSection? = nil, sharing: Bool = false) {
        if let section { navigation.section = section }
        if sharing { navigation.sharing = true }
        if window == nil {
            let view = StatsView(store: store, usage: store.usage, navigation: navigation)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = String(localized: "Statistics")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            // Wide enough for the whole toolbar in English and Spanish.
            window.setContentSize(NSSize(width: 1080, height: 720))
            window.contentMinSize = NSSize(width: 860, height: 560)
            window.setFrameAutosaveName("Statistics.v2")
            if window.frame.origin == .zero { window.center() }
            self.window = window
        }
        // Newly appended lines show up as soon as the window opens.
        store.usage.update()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
