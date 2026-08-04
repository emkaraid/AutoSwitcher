// Renders the AutoSwitcher app icon: macOS-style rounded square with a
// blue-violet gradient and two overlapping white keycaps — "A" and "Я".
// Usage: swift icon_gen.swift /path/to/output.png

import AppKit

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255.0,
        green: CGFloat((hex >> 8) & 0xFF) / 255.0,
        blue: CGFloat(hex & 0xFF) / 255.0,
        alpha: 1.0
    )
}

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "icon_1024.png"

let S: CGFloat = 1024
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
let gctx = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.current = gctx
let ctx = gctx.cgContext

// ---------- Background: Apple-style rounded square with gradient ----------
let bgRect = NSRect(x: 100, y: 100, width: 824, height: 824)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 185, yRadius: 185)

// Soft drop shadow behind the tile
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 36,
              color: NSColor.black.withAlphaComponent(0.30).cgColor)
color(0x3B4FD8).setFill()
bgPath.fill()
ctx.restoreGState()

NSGradient(colors: [color(0x6D8CFF), color(0x4757E6), color(0x322FA6)])!
    .draw(in: bgPath, angle: -70)

// Subtle top sheen
ctx.saveGState()
bgPath.addClip()
let sheen = NSBezierPath(ovalIn: NSRect(x: -80, y: 540, width: 1184, height: 700))
NSGradient(starting: NSColor.white.withAlphaComponent(0.16),
           ending: NSColor.white.withAlphaComponent(0.0))!
    .draw(in: sheen, angle: -90)
ctx.restoreGState()

// ---------- Keycaps ----------
func drawKeycap(center: NSPoint, size: CGFloat, letter: String, letterColor: NSColor) {
    let half = size / 2
    let radius = size * 0.23
    let depth: CGFloat = size * 0.075

    // Key shadow on the background
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 44,
                  color: NSColor.black.withAlphaComponent(0.38).cgColor)
    // Side (the "3D" bottom edge of the key)
    let sideRect = NSRect(x: center.x - half, y: center.y - half - depth,
                          width: size, height: size)
    color(0xC9CEDC).setFill()
    NSBezierPath(roundedRect: sideRect, xRadius: radius, yRadius: radius).fill()
    ctx.restoreGState()

    // Top face
    let faceRect = NSRect(x: center.x - half, y: center.y - half,
                          width: size, height: size)
    let facePath = NSBezierPath(roundedRect: faceRect, xRadius: radius, yRadius: radius)
    NSGradient(starting: NSColor.white, ending: color(0xE9EBF2))!
        .draw(in: facePath, angle: -90)

    // Letter
    let font = NSFont.systemFont(ofSize: size * 0.60, weight: .heavy)
    let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: letterColor]
    let str = NSAttributedString(string: letter, attributes: attr)
    let ts = str.size()
    str.draw(at: NSPoint(x: center.x - ts.width / 2,
                         y: center.y - ts.height / 2 + size * 0.015))
}

// "A" — top-left, USA-blue; "Я" — bottom-right, RF-red; Я overlaps on top.
drawKeycap(center: NSPoint(x: 418, y: 592), size: 336,
           letter: "A", letterColor: color(0x2F5BE7))
drawKeycap(center: NSPoint(x: 614, y: 438), size: 336,
           letter: "Я", letterColor: color(0xE03E3C))

NSGraphicsContext.current?.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

let png = bitmap.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outPath))
print("written: \(outPath)")
