// Renders the social media cover. Usage: swift MakeCover.swift <screenshot.png> <output.png> <width> <height>
// Facebook page cover: 1640×624 (the middle ~1110 px stays visible on phones). Post / link image: 1200×630.
import AppKit

let args = CommandLine.arguments
let shotPath = args[1], output = args[2]
let W = CGFloat(Double(args[3]) ?? 1640), H = CGFloat(Double(args[4]) ?? 624)
let wide = W / H > 2.2   // the cover: content kept in the phone-safe middle

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
let pink = rgb(1.0, 0.36, 0.54), orange = rgb(1.0, 0.66, 0.13), green = rgb(0.24, 0.86, 0.59), blue = rgb(0.36, 0.66, 1.0)
let stems = [pink, orange, green, blue]
let bg = rgb(0.043, 0.043, 0.051)
func italicHeavy(_ s: CGFloat) -> NSFont {
    NSFontManager.shared.convert(NSFont.systemFont(ofSize: s, weight: .black), toHaveTrait: .italicFontMask)
}

// Background: near black, a blue glow behind the screenshot, a pink one behind the logo, fine dot grain.
bg.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
NSGradient(colors: [blue.withAlphaComponent(0.28), .clear])!
    .draw(fromCenter: NSPoint(x: W * 0.74, y: H * 0.5), radius: 0, toCenter: NSPoint(x: W * 0.74, y: H * 0.5), radius: H * 0.95, options: [])
NSGradient(colors: [pink.withAlphaComponent(0.13), .clear])!
    .draw(fromCenter: NSPoint(x: W * 0.3, y: H * 0.62), radius: 0, toCenter: NSPoint(x: W * 0.3, y: H * 0.62), radius: H * 0.8, options: [])
NSColor.white.withAlphaComponent(0.03).setFill()
var gy: CGFloat = 4
while gy < H { var gx: CGFloat = 4; while gx < W { NSBezierPath(ovalIn: NSRect(x: gx, y: gy, width: 2, height: 2)).fill(); gx += 10 }; gy += 10 }

// Four faint stem waveforms running across the whole picture, like lanes.
for (i, c) in stems.enumerated() {
    let mid = H * (0.2 + 0.2 * CGFloat(i))
    c.withAlphaComponent(0.07).setFill()
    var x: CGFloat = 0, k = 0
    while x < W {
        let ph = Double(k) * 0.21 + Double(i) * 1.7
        let env = 0.2 + 0.8 * abs(sin(ph) * cos(ph * 0.29 + Double(i)))
        let h = CGFloat(env) * H * 0.06
        NSRect(x: x, y: mid - h, width: 3, height: h * 2).fill()
        x += 6; k += 1
    }
}

// The app screenshot, slightly turned, with a glow and a shadow.
if let shot = NSImage(contentsOfFile: shotPath) {
    let sw = wide ? W * 0.47 : W * 0.56
    let sh = sw * shot.size.height / shot.size.width
    let sx = wide ? W * 0.535 : W * 0.5, sy = (H - sh) / 2 - H * 0.02
    ctx.saveGState()
    ctx.translateBy(x: sx + sw / 2, y: sy + sh / 2)
    ctx.rotate(by: 2.2 * .pi / 180)
    let r = CGRect(x: -sw / 2, y: -sh / 2, width: sw, height: sh)
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
    shadow.shadowBlurRadius = H * 0.07; shadow.shadowOffset = NSSize(width: 0, height: -H * 0.02)
    NSGraphicsContext.saveGraphicsState(); shadow.set()
    NSColor.black.setFill(); NSBezierPath(roundedRect: r, xRadius: sw * 0.012, yRadius: sw * 0.012).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSBezierPath(roundedRect: r, xRadius: sw * 0.012, yRadius: sw * 0.012).addClip()
    shot.draw(in: r)
    ctx.restoreGState()
    // Thin bright frame.
    ctx.saveGState()
    ctx.translateBy(x: sx + sw / 2, y: sy + sh / 2); ctx.rotate(by: 2.2 * .pi / 180)
    NSColor.white.withAlphaComponent(0.14).setStroke()
    let fr = NSBezierPath(roundedRect: CGRect(x: -sw / 2, y: -sh / 2, width: sw, height: sh), xRadius: sw * 0.012, yRadius: sw * 0.012)
    fr.lineWidth = 1.5; fr.stroke()
    ctx.restoreGState()
}

// Left column (inside the phone-safe middle on the cover).
let left = wide ? W * 0.175 : W * 0.06
let unit = H / 624   // sizes below are for a 624 px high picture

// The logo: STEM + the skewed EKI badge of the four stem bands, with "EKI" cut out of it.
func logo(x: CGFloat, baseline: CGFloat, h: CGFloat) -> CGFloat {
    let stem = NSAttributedString(string: "STEM", attributes: [.font: italicHeavy(h * 0.92), .foregroundColor: NSColor.white, .kern: -h * 0.02])
    let sw = stem.size().width
    stem.draw(at: NSPoint(x: x, y: baseline - h * 0.2))
    let bw = h * 1.62, bh = h * 0.86
    let bx = x + sw + h * 0.16, by = baseline - h * 0.06
    let skew = CGAffineTransform(a: 1, b: 0, c: 0.25, d: 1, tx: -(by + bh / 2) * 0.25, ty: 0)
    func badge(_ dx: CGFloat, _ dy: CGFloat) -> CGPath { CGPath(rect: CGRect(x: bx + dx, y: by + dy, width: bw, height: bh), transform: [skew]) }
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.saveGState(); ctx.addPath(badge(h * 0.07, -h * 0.07)); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath(); ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(badge(0, 0)); ctx.clip()
    for (i, c) in stems.enumerated() {
        ctx.setFillColor(c.cgColor)
        ctx.fill(CGRect(x: bx - bh, y: by + bh - CGFloat(i + 1) * bh / 4, width: bw + 2 * bh, height: bh / 4 + 0.5))
        let mid = by + bh - CGFloat(i + 1) * bh / 4 + bh / 8
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.38).cgColor)
        var xx = bx - bh, k = 0
        while xx < bx + bw + bh {
            let ph = Double(k) * 0.55 + Double(i) * 1.3
            let env = 0.25 + 0.75 * abs(sin(ph) * cos(ph * 0.37 + Double(i)))
            let wh = CGFloat(env) * bh / 8 * 0.8
            ctx.fill(CGRect(x: xx, y: mid - wh, width: h * 0.022, height: wh * 2))
            xx += h * 0.042; k += 1
        }
    }
    ctx.restoreGState()
    let eki = NSAttributedString(string: "EKI", attributes: [.font: italicHeavy(h * 0.8), .foregroundColor: NSColor.white, .kern: -h * 0.015])
    let ez = eki.size()
    ctx.setBlendMode(.destinationOut)
    eki.draw(at: NSPoint(x: bx + (bw - ez.width) / 2 + h * 0.02, y: by + (bh - ez.height) / 2 + h * 0.03))
    ctx.setBlendMode(.normal)
    ctx.endTransparencyLayer()
    return bx + bw + bh * 0.25 - x
}

var y = H * 0.74
let logoW = logo(x: left, baseline: y, h: 96 * unit)

// Tagline with the four-colour line.
y -= 50 * unit
let tag = NSAttributedString(string: "S T E M S   ·   L O O P S   ·   R E M I X",
                             attributes: [.font: NSFont.systemFont(ofSize: 15 * unit, weight: .heavy), .foregroundColor: rgb(0.62, 0.64, 0.72)])
tag.draw(at: NSPoint(x: left + 4 * unit, y: y))
for (i, c) in stems.enumerated() {
    c.setFill()
    NSBezierPath(roundedRect: NSRect(x: left + 4 * unit + CGFloat(i) * (logoW / 4), y: y - 12 * unit, width: logoW / 4 - 6 * unit, height: 4 * unit),
                 xRadius: 2 * unit, yRadius: 2 * unit).fill()
}

// Headline.
y -= 92 * unit
let head = NSMutableAttributedString(string: "Split any song.\nRebuild it. ", attributes: [
    .font: NSFont.systemFont(ofSize: 40 * unit, weight: .heavy), .foregroundColor: NSColor.white,
    .paragraphStyle: { let p = NSMutableParagraphStyle(); p.lineSpacing = -2 * unit; return p }()])
head.append(NSAttributedString(string: "Loop it.", attributes: [.font: NSFont.systemFont(ofSize: 40 * unit, weight: .heavy), .foregroundColor: green]))
head.draw(at: NSPoint(x: left + 2 * unit, y: y - 40 * unit))

// What it is.
y -= 84 * unit
let sub = NSAttributedString(string: "AI stem separation, a beat-exact grid and DAW-ready loops.\nFree for Mac · runs on your Mac, your music never leaves it.",
                             attributes: [.font: NSFont.systemFont(ofSize: 15.5 * unit, weight: .medium), .foregroundColor: rgb(0.78, 0.8, 0.86),
                                          .paragraphStyle: { let p = NSMutableParagraphStyle(); p.lineSpacing = 4 * unit; return p }()])
sub.draw(at: NSPoint(x: left + 3 * unit, y: y - 26 * unit))

// The address, as a button.
y -= 76 * unit
let url = NSAttributedString(string: "ekidio.github.io/stemeki", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 15 * unit, weight: .bold), .foregroundColor: rgb(0.03, 0.1, 0.06)])
let us = url.size()
let pill = NSRect(x: left + 3 * unit, y: y - 10 * unit, width: us.width + 34 * unit, height: us.height + 18 * unit)
let glow = NSShadow(); glow.shadowColor = green.withAlphaComponent(0.5); glow.shadowBlurRadius = 18 * unit; glow.shadowOffset = .zero
NSGraphicsContext.saveGraphicsState(); glow.set(); green.setFill()
NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
NSGraphicsContext.restoreGraphicsState()
url.draw(at: NSPoint(x: pill.minX + 17 * unit, y: pill.minY + 9 * unit))
let made = NSAttributedString(string: "by EKIDIO SOUND", attributes: [.font: NSFont.systemFont(ofSize: 12 * unit, weight: .heavy), .foregroundColor: rgb(0.52, 0.54, 0.62), .kern: 2 * unit])
made.draw(at: NSPoint(x: pill.maxX + 18 * unit, y: pill.midY - made.size().height / 2))

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
