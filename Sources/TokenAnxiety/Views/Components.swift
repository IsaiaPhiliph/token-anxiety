import AppKit
import SwiftUI
import TokenAnxietyCore

extension UsageLevel {
    var color: Color {
        switch self {
        case .calm: .green
        case .moderate: .yellow
        case .warning: .orange
        case .critical: .red
        }
    }
}

/// The panel's headline: how anxious the figures in the menu bar should make you.
enum Mood {
    case unknown, zen, calm, uneasy, anxious, panic, blocked

    @MainActor
    init(worst: Double?, settings: AppSettings) {
        guard let worst else { self = .unknown; return }
        switch worst {
        case 100...: self = .blocked
        case Double(settings.criticalThreshold)...: self = .panic
        case Double(settings.warnThreshold)...: self = .anxious
        case 50...: self = .uneasy
        case 25...: self = .calm
        default: self = .zen
        }
    }

    var phrase: String {
        switch self {
        case .unknown: "Buscando tus planes…"
        case .zen: "Zen total. Quema tokens sin miedo."
        case .calm: "Todo bajo control."
        case .uneasy: "Ligera inquietud."
        case .anxious: "Ansiedad de tokens."
        case .panic: "Pánico. Raciona."
        case .blocked: "Bloqueado. Toca hierba."
        }
    }

    var color: Color {
        switch self {
        case .unknown: .gray
        case .zen: .mint
        case .calm: .green
        case .uneasy: .yellow
        case .anxious: .orange
        case .panic: .red
        case .blocked: .pink
        }
    }
}

/// A rounded bar with an optional tick where an even pace would be.
struct UsageBar: View {
    var value: Double
    var marker: Double? = nil
    var tint: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: value > 0 ? max(height, width * min(1, value / 100)) : 0)
                if let marker, marker > 0, marker < 100 {
                    Capsule()
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 2, height: height + 6)
                        .offset(x: width * marker / 100 - 1)
                }
            }
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.5), value: value)
    }
}

struct PlanBadge: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.09)))
            .foregroundStyle(.secondary)
    }
}

/// The installed app's own icon, or a drawn glyph when the app is missing.
struct ProviderIcon: View {
    var id: ProviderID
    var size: CGFloat = 26

    var body: some View {
        if let icon = AppIcons.icon(for: id) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(nsImage: ProviderGlyph.image(id, size: size * 0.55, color: .white))
                .frame(width: size, height: size)
                .background(Circle().fill(Color.gray.gradient))
        }
    }
}

@MainActor
enum AppIcons {
    private static var cache: [ProviderID: NSImage?] = [:]

    static func icon(for id: ProviderID) -> NSImage? {
        if let cached = cache[id] { return cached }
        let workspace = NSWorkspace.shared
        var url = id.appBundleIdentifiers.lazy.compactMap { workspace.urlForApplication(withBundleIdentifier: $0) }.first
        if url == nil {
            let folders = ["/Applications", NSHomeDirectory() + "/Applications"]
            url = id.appNames.lazy.flatMap { name in folders.map { URL(fileURLWithPath: "\($0)/\(name).app") } }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }
        let image = url.map { workspace.icon(forFile: $0.path) }
        cache[id] = image
        return image
    }
}
