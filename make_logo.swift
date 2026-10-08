// Draws VN Library's app icon (logo.png): a dark squircle with three book spines.
import AppKit

let n = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(n), pixelsHigh: Int(n),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
func c(_ h: UInt32, _ a: Double = 1) -> NSColor {
    NSColor(srgbRed: Double((h >> 16) & 255) / 255, green: Double((h >> 8) & 255) / 255,
            blue: Double(h & 255) / 255, alpha: a)
}
let inset = 100.0
let tile = NSRect(x: inset, y: inset, width: n - 2 * inset, height: n - 2 * inset)
let bg = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(starting: c(0x2A1B4D), ending: c(0x121214))!.draw(in: bg, angle: -90)
c(0x8B5CF6, 0.5).setStroke(); bg.lineWidth = 6; bg.stroke()

// Shelf
let shelf = NSBezierPath(roundedRect: NSRect(x: 230, y: 285, width: 564, height: 34), xRadius: 17, yRadius: 17)
c(0x8B8B96).setFill(); shelf.fill()

// Books: (x, width, height, color, tilt)
let books: [(Double, Double, Double, UInt32, Double)] = [
    (262, 118, 400, 0x8B5CF6, 0),
    (398, 104, 450, 0xECECF1, 0),
    (520, 112, 360, 0xEF4444, 0),
]
for (x, w, h, col, _) in books {
    let r = NSRect(x: x, y: 319, width: w, height: h)
    let p = NSBezierPath(roundedRect: r, xRadius: 16, yRadius: 16)
    c(col).setFill(); p.fill()
    c(0x000000, 0.18).setFill()
    NSBezierPath(rect: NSRect(x: x + 18, y: 319 + h - 90, width: w - 36, height: 16)).fill()
    NSBezierPath(rect: NSRect(x: x + 18, y: 319 + 70, width: w - 36, height: 16)).fill()
}
// Leaning book
NSGraphicsContext.current!.saveGraphicsState()
let t = NSAffineTransform(); t.translateX(by: 650, yBy: 319); t.rotate(byDegrees: -16); t.concat()
let lean = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 108, height: 410), xRadius: 16, yRadius: 16)
c(0xFB923C).setFill(); lean.fill()
c(0x000000, 0.18).setFill()
NSBezierPath(rect: NSRect(x: 18, y: 320, width: 72, height: 16)).fill()
NSGraphicsContext.current!.restoreGraphicsState()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "logo.png"))
