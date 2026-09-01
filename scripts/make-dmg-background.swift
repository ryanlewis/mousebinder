import AppKit
import Foundation

// Finder background for the release DMG: a graphite canvas (same family as the
// app icon) with an arrow from where the app sits to where the Applications
// symlink sits, plus a one-line caption. The icon positions are set by
// `just dmg` and must match APP_X / APPS_X below.
//
// Usage: swift scripts/make-dmg-background.swift <out.png>
// Writes a 660x400 pixel PNG. Finder (macOS 26, verified) draws a background
// picture at its pixel size and ignores DPI and multi-resolution TIFFs, so a
// 2x image just comes out twice as large; 1x is the only size that lays out
// correctly, at the cost of being slightly soft on Retina displays.

_ = NSApplication.shared

let width: CGFloat = 660
let height: CGFloat = 400
let appX: CGFloat = 180      // centre of MouseBinder.app icon
let appsX: CGFloat = 480     // centre of the Applications symlink
let iconY: CGFloat = 190     // icon centre row, measured from the top in Finder terms

func render(scale: CGFloat) -> NSBitmapImageRep {
    let pw = Int(width * scale), ph = Int(height * scale)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: width, height: height)

    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.cgContext.scaleBy(x: scale, y: scale)

    let bounds = NSRect(x: 0, y: 0, width: width, height: height)
    NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.17, blue: 0.20, alpha: 1),
                        NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1)])!
        .draw(in: bounds, angle: -90)

    // AppKit's origin is bottom-left; Finder positions are top-left.
    let y = height - iconY
    let stroke = NSColor(white: 1, alpha: 0.55)
    stroke.setStroke()

    // Shaft: from the right edge of the app icon to the left edge of the folder.
    let x0 = appX + 84, x1 = appsX - 84
    let shaft = NSBezierPath()
    shaft.lineWidth = 5
    shaft.lineCapStyle = .round
    shaft.move(to: NSPoint(x: x0, y: y))
    shaft.line(to: NSPoint(x: x1 - 10, y: y))
    shaft.stroke()

    // Head.
    let head = NSBezierPath()
    head.lineWidth = 5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.move(to: NSPoint(x: x1 - 26, y: y + 16))
    head.line(to: NSPoint(x: x1 - 8, y: y))
    head.line(to: NSPoint(x: x1 - 26, y: y - 16))
    head.stroke()

    // Caption, below the icon row so it clears the Finder labels.
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let caption = NSAttributedString(
        string: "Drag MouseBinder into Applications, then open it from there.",
        attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: 0.6),
            .paragraphStyle: para,
        ])
    caption.draw(in: NSRect(x: 40, y: 48, width: width - 80, height: 24))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: make-dmg-background.swift <out.png>\n".data(using: .utf8)!)
    exit(2)
}
let png = render(scale: 1).representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: args[1]))
print("wrote \(args[1]) (\(Int(width))x\(Int(height)))")
