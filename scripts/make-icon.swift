// Renders Resources/AppIcon.icns: the ControlBar brand mark (ControlFix design-system palette).
// Source of truth for the mark is ~/develop/assets/Icons/ControlBar/controlbar-mark.svg — keep them in sync.
// Run: swift scripts/make-icon.swift
import AppKit

func color(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
    NSColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
}

let navy = color(0x10, 0x1D, 0x33)
let ink = color(0x07, 0x0C, 0x17)
let lime = color(0xA9, 0xF0, 0x00)
let limeDeep = color(0x7C, 0xC8, 0x00)
let mint = color(0x31, 0xDC, 0xC0)
let teal = color(0x17, 0xB3, 0xA4)
let tealDeep = color(0x0E, 0x8E, 0x93)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Map the mark's 100x100 SVG coordinate space onto this pixel size, flipping Y
    // (SVG is top-left origin, AppKit's default bitmap context is bottom-left).
    let scale = CGFloat(px) / 100
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * scale, y: (100 - y) * scale) }
    func rectFrom(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x * scale, y: (100 - y - h) * scale, width: w * scale, height: h * scale)
    }

    let bgRect = rectFrom(4, 4, 92, 92)
    NSGradient(colors: [navy, ink])!.draw(in: NSBezierPath(roundedRect: bgRect, xRadius: 22 * scale, yRadius: 22 * scale), angle: -45)

    let center = pt(50, 50)
    func polar(_ r: CGFloat, _ deg: CGFloat) -> NSPoint {
        NSPoint(x: center.x + r * scale * cos(deg * .pi / 180), y: center.y + r * scale * sin(deg * .pi / 180))
    }
    let angle: CGFloat = 50

    // Knob face + rim.
    let face = NSBezierPath(ovalIn: NSRect(x: center.x - 30 * scale, y: center.y - 30 * scale, width: 60 * scale, height: 60 * scale))
    NSGradient(colors: [color(0x24, 0x40, 0x6A), color(0x14, 0x25, 0x44)])!.draw(in: face, angle: -45)
    face.lineWidth = 2.6 * scale
    color(0x7F, 0xA0, 0xB3).setStroke()
    face.stroke()

    // Red position line.
    let line = NSBezierPath()
    line.lineWidth = 4.6 * scale
    line.lineCapStyle = .round
    line.move(to: polar(6, angle))
    line.line(to: polar(25, angle))
    color(0xFF, 0x3B, 0x30).setStroke()
    line.stroke()

    // Arrow pointing in at the knob.
    let arrow = NSBezierPath()
    let rad = angle * .pi / 180
    let nx = -sin(rad), ny = cos(rad)
    let base = polar(46, angle)
    arrow.move(to: polar(34, angle))
    arrow.line(to: NSPoint(x: base.x + nx * 5 * scale, y: base.y + ny * 5 * scale))
    arrow.line(to: NSPoint(x: base.x - nx * 5 * scale, y: base.y - ny * 5 * scale))
    arrow.close()
    arrow.lineWidth = 1.6 * scale
    arrow.lineJoinStyle = .round
    lime.setFill(); lime.setStroke()
    arrow.fill(); arrow.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
print("Wrote Resources/AppIcon.icns")
