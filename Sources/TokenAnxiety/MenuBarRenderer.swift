import AppKit
import TokenAnxietyCore

/// Draws the status item: one glyph per service followed by its two figures,
/// in the style chosen in Settings.
enum MenuBarRenderer {
    struct Item: Equatable {
        var provider: ProviderID
        var primary: Double?
        var secondary: Double?
        var dimmed: Bool
    }

    struct Options: Equatable {
        var style: MenuStyle
        var colorize: Bool
        var warn: Double
        var critical: Double
        var dark: Bool
    }

    static let glyphSize: CGFloat = 14
    static let glyphGap: CGFloat = 4
    static let itemGap: CGFloat = 10

    static func image(items: [Item], options: Options, height: CGFloat = NSStatusBar.system.thickness) -> NSImage {
        // A template image follows the menu bar's colours by itself; colour is only
        // needed when a figure is past the warning threshold.
        let colored = options.colorize && items.contains { item in
            [item.primary, item.secondary].contains { ($0 ?? 0) >= options.warn }
        }
        let base: NSColor = colored ? (options.dark ? .white : NSColor.black.withAlphaComponent(0.85)) : .black

        if items.isEmpty {
            let size = NSSize(width: glyphSize + 4, height: height)
            let image = NSImage(size: size, flipped: false) { rect in
                ProviderGlyph.drawGauge(in: CGRect(x: 2, y: (rect.height - glyphSize) / 2, width: glyphSize, height: glyphSize), color: base)
                return true
            }
            image.isTemplate = true
            return image
        }

        let segments = items.map { Segment(item: $0, options: options, base: base, colored: colored) }
        let width = segments.reduce(0) { $0 + $1.width } + itemGap * CGFloat(segments.count - 1) + 2
        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { rect in
            var x: CGFloat = 1
            for segment in segments {
                segment.draw(at: x, height: rect.height)
                x += segment.width + itemGap
            }
            return true
        }
        image.isTemplate = !colored
        return image
    }

    private struct Segment {
        let item: Item
        let options: Options
        let base: NSColor
        let colored: Bool

        static var font: NSFont { .monospacedDigitSystemFont(ofSize: 12.5, weight: .medium) }
        static var smallFont: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .semibold) }
        static let barWidth: CGFloat = 26

        private var alpha: CGFloat { item.dimmed ? 0.45 : 1 }

        func color(for value: Double?) -> NSColor {
            guard colored, let value else { return base.withAlphaComponent(base.alphaComponent * alpha) }
            if value >= options.critical { return NSColor.systemRed.withAlphaComponent(alpha) }
            if value >= options.warn { return NSColor.systemOrange.withAlphaComponent(alpha) }
            return base.withAlphaComponent(base.alphaComponent * alpha)
        }

        var text: NSAttributedString {
            let result = NSMutableAttributedString()
            func append(_ string: String, _ color: NSColor, _ font: NSFont = Segment.font) {
                result.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
            }
            switch (item.primary, item.secondary) {
            case (nil, nil):
                append("–", color(for: nil))
            case let (primary?, nil):
                append(Fmt.compactPercent(primary), color(for: primary))
            case let (nil, secondary?):
                append(Fmt.compactPercent(secondary), color(for: secondary))
            case let (primary?, secondary?):
                append(Fmt.compactPercent(primary), color(for: primary))
                append(" · ", base.withAlphaComponent(base.alphaComponent * alpha * 0.6))
                append(Fmt.compactPercent(secondary), color(for: secondary))
            }
            return result
        }

        var smallText: NSAttributedString {
            let value = item.primary ?? item.secondary
            return NSAttributedString(string: value.map(Fmt.compactPercent) ?? "–",
                                      attributes: [.font: Segment.smallFont, .foregroundColor: color(for: value)])
        }

        var contentWidth: CGFloat {
            switch options.style {
            case .percentages: ceil(text.size().width)
            case .bars: Segment.barWidth
            case .numberAndBar: max(ceil(smallText.size().width), 22)
            }
        }

        var width: CGFloat { MenuBarRenderer.glyphSize + MenuBarRenderer.glyphGap + contentWidth }

        func draw(at x: CGFloat, height: CGFloat) {
            let glyphRect = CGRect(x: x, y: (height - MenuBarRenderer.glyphSize) / 2,
                                   width: MenuBarRenderer.glyphSize, height: MenuBarRenderer.glyphSize)
            ProviderGlyph.draw(item.provider, in: glyphRect, color: base.withAlphaComponent(base.alphaComponent * alpha))
            let left = x + MenuBarRenderer.glyphSize + MenuBarRenderer.glyphGap

            switch options.style {
            case .percentages:
                let text = self.text
                let size = text.size()
                text.draw(at: CGPoint(x: left, y: (height - size.height) / 2))
            case .bars:
                let barHeight: CGFloat = 3.5
                let gap: CGFloat = 2.5
                let top = (height + gap) / 2
                drawBar(item.primary, in: CGRect(x: left, y: top, width: Segment.barWidth, height: barHeight))
                drawBar(item.secondary, in: CGRect(x: left, y: top - gap - barHeight, width: Segment.barWidth, height: barHeight))
            case .numberAndBar:
                let text = smallText
                let size = text.size()
                let barHeight: CGFloat = 2.5
                let block = size.height - 2 + 1.5 + barHeight
                let bottom = (height - block) / 2
                text.draw(at: CGPoint(x: left, y: bottom + barHeight + 1.5 - 2))
                drawBar(item.secondary ?? item.primary, in: CGRect(x: left, y: bottom, width: contentWidth, height: barHeight))
            }
        }

        private func drawBar(_ value: Double?, in rect: CGRect) {
            let radius = rect.height / 2
            base.withAlphaComponent(base.alphaComponent * alpha * 0.28).setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            guard let value, value > 0 else { return }
            var fill = rect
            fill.size.width = max(rect.height, rect.width * min(1, value / 100))
            color(for: value).setFill()
            NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
        }
    }
}

/// Small monochrome marks for each service, drawn as paths so they stay
/// sharp at menu bar size.
enum ProviderGlyph {
    static func draw(_ provider: ProviderID, in rect: CGRect, color: NSColor) {
        let s = min(rect.width, rect.height)
        let c = CGPoint(x: rect.midX, y: rect.midY)
        color.setStroke()
        color.setFill()
        switch provider {
        case .claude:
            // A starburst of rounded rays, like Claude's mark.
            let path = NSBezierPath()
            let rays = 11
            for index in 0..<rays {
                let angle = Double(index) / Double(rays) * 2 * .pi + .pi / 2
                let outer = s * (index.isMultiple(of: 2) ? 0.47 : 0.40)
                let inner = s * 0.08
                path.move(to: CGPoint(x: c.x + cos(angle) * inner, y: c.y + sin(angle) * inner))
                path.line(to: CGPoint(x: c.x + cos(angle) * outer, y: c.y + sin(angle) * outer))
            }
            path.lineWidth = s * 0.13
            path.lineCapStyle = .round
            path.stroke()
        case .codex:
            // A rounded terminal with a prompt: Codex is the coding agent.
            let box = NSBezierPath(roundedRect: rect.insetBy(dx: s * 0.06, dy: s * 0.1), xRadius: s * 0.24, yRadius: s * 0.24)
            box.lineWidth = s * 0.1
            box.stroke()
            let prompt = NSBezierPath()
            prompt.move(to: CGPoint(x: rect.minX + s * 0.27, y: c.y + s * 0.15))
            prompt.line(to: CGPoint(x: rect.minX + s * 0.44, y: c.y))
            prompt.line(to: CGPoint(x: rect.minX + s * 0.27, y: c.y - s * 0.15))
            prompt.move(to: CGPoint(x: rect.minX + s * 0.52, y: c.y - s * 0.16))
            prompt.line(to: CGPoint(x: rect.minX + s * 0.73, y: c.y - s * 0.16))
            prompt.lineWidth = s * 0.1
            prompt.lineCapStyle = .round
            prompt.lineJoinStyle = .round
            prompt.stroke()
        case .antigravity:
            // An arch, like Antigravity's mark.
            let path = NSBezierPath()
            let radius = s * 0.33
            let centre = CGPoint(x: c.x, y: rect.minY + s * 0.45)
            path.move(to: CGPoint(x: centre.x - radius, y: rect.minY + s * 0.12))
            path.line(to: CGPoint(x: centre.x - radius, y: centre.y))
            path.appendArc(withCenter: centre, radius: radius, startAngle: 180, endAngle: 0, clockwise: true)
            path.line(to: CGPoint(x: centre.x + radius, y: rect.minY + s * 0.12))
            path.lineWidth = s * 0.17
            path.lineCapStyle = .round
            path.stroke()
        case .cursor:
            // An isometric cube.
            let radius = s * 0.45
            var corners: [CGPoint] = []
            for index in 0..<6 {
                let angle = Double(index) * .pi / 3 + .pi / 2
                corners.append(CGPoint(x: c.x + cos(angle) * radius, y: c.y + sin(angle) * radius))
            }
            let outline = NSBezierPath()
            outline.move(to: corners[0])
            for corner in corners.dropFirst() { outline.line(to: corner) }
            outline.close()
            outline.lineWidth = s * 0.1
            outline.lineJoinStyle = .round
            outline.stroke()
            let edges = NSBezierPath()
            for corner in [corners[0], corners[2], corners[4]] {
                edges.move(to: c)
                edges.line(to: corner)
            }
            edges.lineWidth = s * 0.08
            edges.lineCapStyle = .round
            edges.stroke()
        }
    }

    /// The app's own mark: a gauge whose needle is in the red.
    static func drawGauge(in rect: CGRect, color: NSColor) {
        let s = min(rect.width, rect.height)
        let centre = CGPoint(x: rect.midX, y: rect.minY + s * 0.3)
        let arc = NSBezierPath()
        arc.appendArc(withCenter: centre, radius: s * 0.42, startAngle: 180, endAngle: 0, clockwise: true)
        arc.lineWidth = s * 0.12
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
        let needle = NSBezierPath()
        needle.move(to: centre)
        needle.line(to: CGPoint(x: centre.x + s * 0.3, y: centre.y + s * 0.22))
        needle.lineWidth = s * 0.12
        needle.lineCapStyle = .round
        needle.stroke()
        color.setFill()
        NSBezierPath(ovalIn: CGRect(x: centre.x - s * 0.09, y: centre.y - s * 0.09, width: s * 0.18, height: s * 0.18)).fill()
    }

    static func image(_ provider: ProviderID?, size: CGFloat, color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            if let provider { draw(provider, in: rect, color: color) } else { drawGauge(in: rect, color: color) }
            return true
        }
    }
}
