// Renders the app icon at 1024×1024 (macOS icon grid: an 824 pt tile with a soft
// shadow): a menu bar split by the notch, with icons on both wings; the left
// wing's icons glow in the accent colour. Usage: swift scripts/make-icon.swift <out.png>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
let canvas = 1024

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = context
let g = context.cgContext
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func fillGradient(_ path: CGPath, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    g.saveGState()
    g.addPath(path)
    g.clip()
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    g.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    g.restoreGState()
}

// ── Tile ─────────────────────────────────────────────────────────────
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = rounded(tile, 186)
g.saveGState()
g.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
g.addPath(tilePath)
g.setFillColor(rgb(0x1B1F2A))
g.fillPath()
g.restoreGState()
fillGradient(tilePath, [rgb(0x2A3142), rgb(0x10131B)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))

// ── Desktop glow under the bar ───────────────────────────────────────
g.saveGState()
g.addPath(tilePath)
g.clip()
let glow = CGGradient(colorsSpace: space, colors: [rgb(0x5B7CFA, 0.45), rgb(0x5B7CFA, 0)] as CFArray, locations: nil)!
g.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 560), startRadius: 0, endCenter: CGPoint(x: 330, y: 560), endRadius: 420, options: [])
g.restoreGState()

// ── Menu bar ─────────────────────────────────────────────────────────
let bar = CGRect(x: 100, y: 610, width: 824, height: 150)
g.saveGState()
g.addPath(tilePath)
g.clip()
g.setFillColor(rgb(0x0B0D12, 0.92))
g.fill(bar)
g.setFillColor(CGColor(gray: 1, alpha: 0.08))
g.fill(CGRect(x: bar.minX, y: bar.minY, width: bar.width, height: 3))
g.restoreGState()

// The notch: black, hanging from the top of the tile, rounded at the bottom.
let notch = CGRect(x: 432, y: 640, width: 160, height: 300)
g.saveGState()
g.addPath(tilePath)
g.clip()
g.addPath(rounded(notch, 34))
g.setFillColor(rgb(0x000000))
g.fillPath()
g.restoreGState()

// ── Icons on both wings ──────────────────────────────────────────────
let iconY: CGFloat = 662
let iconSize: CGFloat = 46
func icon(at x: CGFloat, _ color: CGColor, round: Bool = false) {
    let r = CGRect(x: x, y: iconY, width: iconSize, height: iconSize)
    g.addPath(round ? CGPath(ellipseIn: r, transform: nil) : rounded(r, 12))
    g.setFillColor(color)
    g.fillPath()
}
// Right wing: the usual white icons.
for (i, x) in [622.0, 690.0, 758.0, 836.0].enumerated() { icon(at: x, CGColor(gray: 1, alpha: i == 3 ? 0.55 : 0.85), round: i == 1) }
// Left wing: the icons that used to vanish behind the notch, now glowing.
g.saveGState()
g.setShadow(offset: .zero, blur: 22, color: rgb(0x7FA2FF, 0.9))
for (i, x) in [196.0, 264.0, 332.0].enumerated() { icon(at: x, [rgb(0x8FB0FF), rgb(0xB9A3FF), rgb(0x7FE3FF)][i], round: i == 1) }
g.restoreGState()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
