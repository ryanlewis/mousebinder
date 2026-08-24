import AppKit
import Foundation

// MouseBinder app icon: the standard SF Symbols `computermouse` glyph (clean
// outline mouse) on a graphite squircle, with a small accent bracket on the left
// marking the thumb / side buttons — which is what this app remaps.

_ = NSApplication.shared  // initialise AppKit so SF Symbols render headless

func tintedSymbol(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
    let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
        .withSymbolConfiguration(cfg)!
    let size = base.size
    return NSImage(size: size, flipped: false) { rect in
        base.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
}

func makeIcon(pixels: Int) -> Data {
    let s = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: s, height: s)

    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    // Background squircle with a graphite gradient.
    let corner = s * 0.2237
    let bgPath = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                             xRadius: corner, yRadius: corner)
    bgPath.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.17, green: 0.18, blue: 0.21, alpha: 1),
                        NSColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 1)])!
        .draw(in: NSRect(x: 0, y: 0, width: s, height: s), angle: -90)

    // The mouse glyph, centred.
    let mouse = tintedSymbol("computermouse", pointSize: s * 0.52, color: .white)
    let m = mouse.size
    let mouseRect = NSRect(x: (s - m.width) / 2, y: (s - m.height) / 2, width: m.width, height: m.height)
    mouse.draw(in: mouseRect)

    // Accent side button — a small thumb button protruding from the left edge of
    // the mouse, the button this app exists to remap.
    let accent = NSColor(srgbRed: 0.23, green: 0.51, blue: 0.96, alpha: 1)
    let nubW = m.width * 0.16
    let nubH = m.height * 0.17
    let bodyLeftEdge = mouseRect.minX + m.width * 0.135
    let nubRect = NSRect(x: bodyLeftEdge - nubW * 0.78,   // mostly outside the body
                         y: mouseRect.midY + m.height * 0.015,
                         width: nubW, height: nubH)
    let nubCorner = min(nubW, nubH) * 0.42
    accent.setFill()
    NSBezierPath(roundedRect: nubRect, xRadius: nubCorner, yRadius: nubCorner).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: make-icon.swift <iconset-dir> <preview.png>\n".data(using: .utf8)!)
    exit(1)
}
let iconsetDir = args[1]
let previewPath = args[2]

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in specs {
    try makeIcon(pixels: px).write(to: URL(fileURLWithPath: iconsetDir).appendingPathComponent(name))
}
try makeIcon(pixels: 512).write(to: URL(fileURLWithPath: previewPath))
print("icon assets written")
