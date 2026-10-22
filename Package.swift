// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TokenAnxiety",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "TokenAnxiety", targets: ["TokenAnxiety"]),
    ],
    targets: [
        // Everything that can be tested without a window: the providers, their
        // parsers, pace, history and alert rules.
        .target(
            name: "TokenAnxietyCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // The menu bar app itself (AppKit + SwiftUI).
        .executableTarget(
            name: "TokenAnxiety",
            dependencies: ["TokenAnxietyCore"]
        ),
        .testTarget(
            name: "TokenAnxietyCoreTests",
            dependencies: ["TokenAnxietyCore"]
        ),
    ]
)
