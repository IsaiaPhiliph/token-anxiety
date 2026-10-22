// Draws the app icon (a gauge with its needle in the red and a sweat drop)
// and writes <dir>/AppIcon.icns.  Usage: swift scripts/make-icon.swift Resources
import AppKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources")

func drawIcon(in context: CGContext, size: CGFloat) {
    let scale = size / 1024
    context.saveGState()
    context.scaleBy(x: scale, y: scale)

    // The macOS icon grid: an 824 pt rounded square centred on 1024.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // Drop shadow under the tile.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    context.addPath(shape)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    context.restoreGState()

    // Deep night background.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let background = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 0.20, green: 0.21, blue: 0.36, alpha: 1).cgColor,
        NSColor(red: 0.07, green: 0.07, blue: 0.13, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // A soft red glow behind the danger zone.
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 1, green: 0.25, blue: 0.2, alpha: 0.38).cgColor,
        NSColor(red: 1, green: 0.25, blue: 0.2, alpha: 0).cgColor,
    ] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 700, y: 560), startRadius: 0,
                               endCenter: CGPoint(x: 700, y: 560), endRadius: 420, options: [])

    // The gauge: an arc from green to red, made of short segments.
    let centre = CGPoint(x: 512, y: 430)
    let radius: CGFloat = 268
    let stops: [(CGFloat, NSColor)] = [
        (0, NSColor(red: 0.20, green: 0.85, blue: 0.55, alpha: 1)),
        (0.45, NSColor(red: 1.00, green: 0.84, blue: 0.25, alpha: 1)),
        (0.72, NSColor(red: 1.00, green: 0.55, blue: 0.20, alpha: 1)),
        (1, NSColor(red: 1.00, green: 0.24, blue: 0.27, alpha: 1)),
    ]
    func color(at t: CGFloat) -> NSColor {
        for index in 1..<stops.count where t <= stops[index].0 {
            let (t0, c0) = stops[index - 1]
            let (t1, c1) = stops[index]
            return c0.blended(withFraction: (t - t0) / (t1 - t0), of: c1) ?? c1
        }
        return stops.last!.1
    }
    context.setLineCap(.round)
    context.setLineWidth(88)
    let segments = 160
    context.setLineCap(.butt)
    for index in 0..<segments {
        let t0 = CGFloat(index) / CGFloat(segments)
        let t1 = CGFloat(index + 1) / CGFloat(segments)
        let a0 = .pi * (1 - t0)
        let a1 = .pi * (1 - t1) - 0.004
        context.setStrokeColor(color(at: t0).cgColor)
        context.addArc(center: centre, radius: radius, startAngle: a0, endAngle: a1, clockwise: true)
        context.strokePath()
    }
    // Round caps at both ends.
    for (angle, t) in [(CGFloat.pi, CGFloat(0)), (0, CGFloat(1))] {
        let point = CGPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)
        context.setFillColor(color(at: t).cgColor)
        context.fillEllipse(in: CGRect(x: point.x - 44, y: point.y - 44, width: 88, height: 88))
    }

    // Glassy highlight on the arc.
    context.setLineCap(.round)
    context.setLineWidth(18)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
    context.addArc(center: centre, radius: radius + 22, startAngle: .pi * 0.92, endAngle: .pi * 0.55, clockwise: true)
    context.strokePath()

    // The needle, deep in the red.
    let needleAngle = CGFloat.pi * 0.16
    let tip = CGPoint(x: centre.x + cos(needleAngle) * 230, y: centre.y + sin(needleAngle) * 230)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: NSColor.black.withAlphaComponent(0.5).cgColor)
    context.setStrokeColor(NSColor.white.cgColor)
    context.setLineWidth(40)
    context.setLineCap(.round)
    context.move(to: centre)
    context.addLine(to: tip)
    context.strokePath()
    context.setFillColor(NSColor.white.cgColor)
    context.fillEllipse(in: CGRect(x: centre.x - 62, y: centre.y - 62, width: 124, height: 124))
    context.restoreGState()
    context.setFillColor(NSColor(red: 0.12, green: 0.12, blue: 0.2, alpha: 1).cgColor)
    context.fillEllipse(in: CGRect(x: centre.x - 24, y: centre.y - 24, width: 48, height: 48))

    // The sweat drop, top left of the gauge.
    let drop = CGMutablePath()
    let dropCentre = CGPoint(x: 292, y: 784)
    let dropRadius: CGFloat = 62
    drop.move(to: CGPoint(x: dropCentre.x, y: dropCentre.y + dropRadius * 2.05))
    drop.addCurve(to: CGPoint(x: dropCentre.x + dropRadius, y: dropCentre.y),
                  control1: CGPoint(x: dropCentre.x + dropRadius * 0.25, y: dropCentre.y + dropRadius * 1.45),
                  control2: CGPoint(x: dropCentre.x + dropRadius, y: dropCentre.y + dropRadius * 0.75))
    drop.addArc(center: dropCentre, radius: dropRadius, startAngle: 0, endAngle: .pi, clockwise: true)
    drop.addCurve(to: CGPoint(x: dropCentre.x, y: dropCentre.y + dropRadius * 2.05),
                  control1: CGPoint(x: dropCentre.x - dropRadius, y: dropCentre.y + dropRadius * 0.75),
                  control2: CGPoint(x: dropCentre.x - dropRadius * 0.25, y: dropCentre.y + dropRadius * 1.45))
    drop.closeSubpath()
    context.saveGState()
    context.addPath(drop)
    context.clip()
    let water = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 0.55, green: 0.9, blue: 1, alpha: 1).cgColor,
        NSColor(red: 0.2, green: 0.6, blue: 1, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(water, start: CGPoint(x: dropCentre.x, y: dropCentre.y + dropRadius * 2),
                               end: CGPoint(x: dropCentre.x, y: dropCentre.y - dropRadius), options: [])
    context.setFillColor(NSColor.white.withAlphaComponent(0.75).cgColor)
    context.fillEllipse(in: CGRect(x: dropCentre.x - 32, y: dropCentre.y + 4, width: 22, height: 34))
    context.restoreGState()

    // Liquid Glass sheen: a light top edge and a thin rim.
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor.white.withAlphaComponent(0.20).cgColor,
        NSColor.white.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
    context.restoreGState()

    context.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
    context.setLineWidth(4)
    context.strokePath()
    context.restoreGState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    graphics.cgContext.interpolationQuality = .high
    drawIcon(in: graphics.cgContext, size: CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = outputDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try png(size: 1024).write(to: outputDirectory.appendingPathComponent("AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputDirectory.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("✓ \(outputDirectory.appendingPathComponent("AppIcon.icns").path)")
