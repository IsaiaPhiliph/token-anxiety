// A plain gradient behind the panel for README screenshots, so nothing of yours
// shows through the glass. It covers the screen below the menu bar until killed.
//
//   swift scripts/backdrop.swift [dark|light] &
//   CONFIG=debug scripts/build-app.sh --open --demo --open-panel
import AppKit

let dark = CommandLine.arguments.dropFirst().first != "light"
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.main!
let window = NSWindow(contentRect: screen.visibleFrame, styleMask: .borderless, backing: .buffered, defer: false)
// Above every app window, below the menu bar and the panel (.popUpMenu).
window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
window.ignoresMouseEvents = true
window.collectionBehavior = [.canJoinAllSpaces, .stationary]
let gradient = CAGradientLayer()
gradient.colors = (dark
    ? [NSColor(red: 0.20, green: 0.15, blue: 0.42, alpha: 1), NSColor(red: 0.04, green: 0.30, blue: 0.36, alpha: 1)]
    : [NSColor(red: 0.78, green: 0.84, blue: 0.99, alpha: 1), NSColor(red: 0.99, green: 0.85, blue: 0.91, alpha: 1)]).map(\.cgColor)
gradient.startPoint = CGPoint(x: 0, y: 1)
gradient.endPoint = CGPoint(x: 1, y: 0)
let view = NSView()
view.layer = gradient
view.wantsLayer = true
window.contentView = view
window.orderFrontRegardless()
app.run()
