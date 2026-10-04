// Renders the 1024×1024 app icon PNG. Usage: swift MakeIcon.swift <output.png>
// EKIDIO SOUND style (as PADEKI): a bold italic word plus a skewed "EKI" badge, here built from
// the four stem colours.
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
let pink = rgb(1.0, 0.36, 0.54), orange = rgb(1.0, 0.66, 0.13), green = rgb(0.24, 0.86, 0.59), blue = rgb(0.36, 0.66, 1.0)

// Body: macOS icon grid, 824 pt rounded square.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowOffset = NSSize(width: 0, height: -12); shadow.shadowBlurRadius = 28
NSGraphicsContext.saveGraphicsState(); shadow.set(); NSColor.black.setFill(); shape.fill(); NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
shape.addClip()
NSGradient(starting: rgb(0.10, 0.10, 0.13), ending: rgb(0.03, 0.03, 0.04))!.draw(in: shape, angle: -90)
// Soft coloured glow behind the badge.
let glow = NSGradient(colors: [blue.withAlphaComponent(0.30), pink.withAlphaComponent(0.10), .clear])!
glow.draw(fromCenter: NSPoint(x: 512, y: 430), radius: 0, toCenter: NSPoint(x: 512, y: 430), radius: 430, options: [])
// Fine dot grain.
NSColor.white.withAlphaComponent(0.035).setFill()
var y: CGFloat = 104
while y < 920 { var x: CGFloat = 104; while x < 920 { NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 3, height: 3)).fill(); x += 12 }; y += 12 }
NSGraphicsContext.restoreGraphicsState()

func italicHeavy(_ s: CGFloat) -> NSFont {
    let f = NSFont.systemFont(ofSize: s, weight: .black)
    return NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask)
}

// "STEM" in white.
let stem = NSAttributedString(string: "STEM", attributes: [.font: italicHeavy(230), .foregroundColor: NSColor.white, .kern: -6])
let sz = stem.size()
stem.draw(at: NSPoint(x: (size - sz.width) / 2 - 8, y: 560))

// The "EKI" badge: a skewed parallelogram of four stem-coloured bands, white offset shadow.
let bw: CGFloat = 560, bh: CGFloat = 300, bx: CGFloat = (size - bw) / 2 - 6, by: CGFloat = 215
let skew = CGAffineTransform(a: 1, b: 0, c: 0.25, d: 1, tx: -(by + bh / 2) * 0.25, ty: 0)  // leans right, like the italic type
func badgePath(_ dx: CGFloat, _ dy: CGFloat) -> CGPath {
    CGPath(rect: CGRect(x: bx + dx, y: by + dy, width: bw, height: bh), transform: [skew])
}
// The badge in its own layer, so "EKI" can be cut out of it: the icon's background shows through the letters.
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.saveGState(); ctx.addPath(badgePath(22, -22)); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath(); ctx.restoreGState()
ctx.saveGState(); ctx.addPath(badgePath(0, 0)); ctx.clip()
for (i, c) in [pink, orange, green, blue].enumerated() {
    ctx.setFillColor(c.cgColor)
    ctx.fill(CGRect(x: 0, y: by + bh - CGFloat(i + 1) * bh / 4, width: size, height: bh / 4 + 0.5))
}
// A little waveform in every band (what a stem looks like).
for i in 0..<4 {
    let top = by + bh - CGFloat(i + 1) * bh / 4, mid = top + bh / 8
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.38).cgColor)
    var x: CGFloat = -40
    var k = 0
    while x < size + 40 {
        let ph = Double(k) * 0.55 + Double(i) * 1.3
        let env = 0.25 + 0.75 * abs(sin(ph) * cos(ph * 0.37 + Double(i)))
        let h = CGFloat(env) * bh / 8 * 0.8
        ctx.fill(CGRect(x: x, y: mid - h, width: 6, height: h * 2))
        x += 11; k += 1
    }
}
// A thin dark seam between the bands, like stems stacked in lanes.
ctx.setFillColor(NSColor.black.withAlphaComponent(0.18).cgColor)
for i in 1..<4 { ctx.fill(CGRect(x: 0, y: by + CGFloat(i) * bh / 4 - 2, width: size, height: 4)) }
ctx.restoreGState()

let eki = NSAttributedString(string: "EKI", attributes: [.font: italicHeavy(250), .foregroundColor: NSColor.white, .kern: -4])
let ez = eki.size()
ctx.setBlendMode(.destinationOut)
eki.draw(at: NSPoint(x: bx + (bw - ez.width) / 2 - 10, y: by + (bh - ez.height) / 2 + 6))
ctx.setBlendMode(.normal)
ctx.endTransparencyLayer()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
