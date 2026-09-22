// Renders packaging/dmg/background.png and background@2x.png (660×400 pt): brand, arrow, hint text.
// Run: swift scripts/dmg-background.swift
import AppKit

let size = NSSize(width: 660, height: 400)

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Cool off-white ground with a faint violet wash (the site's palette).
    NSGradient(colors: [NSColor(srgbRed: 0.965, green: 0.969, blue: 0.980, alpha: 1),
                        NSColor(srgbRed: 0.925, green: 0.918, blue: 0.965, alpha: 1)])!
        .draw(in: NSRect(origin: .zero, size: size), angle: -90)

    // Faint "flow" lines behind the icons.
    let flow = NSBezierPath()
    for i in 0..<5 {
        let y = 150 + CGFloat(i) * 14
        flow.move(to: NSPoint(x: 0, y: y))
        flow.curve(to: NSPoint(x: size.width, y: y + 10), controlPoint1: NSPoint(x: 220, y: y + 40), controlPoint2: NSPoint(x: 440, y: y - 30))
    }
    NSColor(srgbRed: 0.29, green: 0.23, blue: 0.65, alpha: 0.05).setStroke()
    flow.lineWidth = 2
    flow.stroke()

    // Arrow between the app (x≈170) and Applications (x≈490) at the icons' centre line (y≈200 from bottom).
    let accent = NSColor(srgbRed: 0.29, green: 0.23, blue: 0.65, alpha: 1)
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 262, y: 200))
    arrow.line(to: NSPoint(x: 388, y: 200))
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    accent.withAlphaComponent(0.85).setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 400, y: 200))
    head.line(to: NSPoint(x: 380, y: 214))
    head.line(to: NSPoint(x: 380, y: 186))
    head.close()
    accent.withAlphaComponent(0.85).setFill()
    head.fill()

    func text(_ s: String, _ font: NSFont, _ color: NSColor, y: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let str = NSAttributedString(string: s, attributes: attrs)
        str.draw(at: NSPoint(x: (size.width - str.size().width) / 2, y: y))
    }
    text("Drag Flowlight to Applications", .systemFont(ofSize: 17, weight: .semibold),
         NSColor(srgbRed: 0.07, green: 0.075, blue: 0.10, alpha: 1), y: 88)
    text("Every app. Every domain. Every agent.", .systemFont(ofSize: 12.5, weight: .regular),
         NSColor(srgbRed: 0.34, green: 0.36, blue: 0.44, alpha: 1), y: 64)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: "packaging/dmg")
try render(scale: 1).write(to: dir.appendingPathComponent("background.png"))
try render(scale: 2).write(to: dir.appendingPathComponent("background@2x.png"))
print("wrote packaging/dmg/background.png, background@2x.png")
