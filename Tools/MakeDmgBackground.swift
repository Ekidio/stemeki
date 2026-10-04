// Renders the DMG window background. Usage: swift MakeDmgBackground.swift <out.png> <scale>
// Layout must match Tools/dmg-settings.py (window 680×460, icons at y=170).
import AppKit

let out = CommandLine.arguments[1]
let scale = CGFloat(Double(CommandLine.arguments[2]) ?? 1)
let W: CGFloat = 680, H: CGFloat = 460
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
func y(_ top: CGFloat) -> CGFloat { H - top }
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
let stems = [rgb(1, 0.36, 0.54), rgb(1, 0.66, 0.13), rgb(0.24, 0.86, 0.59), rgb(0.36, 0.66, 1)]

NSGradient(starting: rgb(0.09, 0.09, 0.11), ending: rgb(0.04, 0.04, 0.05))!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)
NSGradient(colors: [stems[3].withAlphaComponent(0.18), .clear])!
    .draw(fromCenter: NSPoint(x: W / 2, y: y(170)), radius: 0, toCenter: NSPoint(x: W / 2, y: y(170)), radius: 300, options: [])

func text(_ s: String, _ font: NSFont, _ color: NSColor, centerX: CGFloat? = nil, x: CGFloat = 0, top: CGFloat, width: CGFloat = 0) {
    let para = NSMutableParagraphStyle(); para.lineSpacing = 2
    let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para, .kern: 0.4])
    if let cx = centerX {
        let size = str.size()
        str.draw(at: NSPoint(x: cx - size.width / 2, y: y(top) - size.height))
    } else {
        let rect = str.boundingRect(with: NSSize(width: width, height: 200), options: [.usesLineFragmentOrigin])
        str.draw(with: NSRect(x: x, y: y(top) - rect.height, width: width, height: rect.height), options: [.usesLineFragmentOrigin])
    }
}
let italic = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 26, weight: .black), toHaveTrait: .italicFontMask)
text("STEMEKI", italic, .white, centerX: W / 2, top: 22)
text("STEMS  ·  LOOPS  ·  REMIX", .monospacedSystemFont(ofSize: 11, weight: .bold), rgb(0.6, 0.62, 0.7), centerX: W / 2, top: 60)
// Four-colour line under the title.
for (i, c) in stems.enumerated() { c.setFill(); NSRect(x: W / 2 - 120 + CGFloat(i) * 60, y: y(84), width: 60, height: 3).fill() }

// Arrow: app icon (x=180) → Applications (x=500), icon centres at y=170.
let arrow = NSBezierPath(); arrow.lineWidth = 4; arrow.lineCapStyle = .round
arrow.move(to: NSPoint(x: 262, y: y(170))); arrow.line(to: NSPoint(x: 410, y: y(170)))
let grad = NSGradient(colors: stems)!
NSGraphicsContext.saveGraphicsState()
arrow.setClip(); grad.draw(in: NSRect(x: 262, y: y(174), width: 160, height: 8), angle: 0)
NSGraphicsContext.restoreGraphicsState()
stems[3].setStroke(); arrow.stroke()
let head = NSBezierPath(); head.move(to: NSPoint(x: 422, y: y(170))); head.line(to: NSPoint(x: 400, y: y(157))); head.line(to: NSPoint(x: 400, y: y(183))); head.close()
stems[3].setFill(); head.fill()

let card = NSRect(x: 30, y: y(440), width: W - 60, height: 172)
rgb(1, 1, 1, 0.05).setFill(); NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14).fill()
rgb(1, 1, 1, 0.1).setStroke(); let border = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14); border.lineWidth = 1; border.stroke()
let steps: [(String, String)] = [
    ("1", "Drag STEMEKI into the Applications folder."),
    ("2", "Open it. If the Mac does not let it start, click “Done”, then:\nSystem Settings → Privacy & Security → scroll down →\n“Open Anyway”. This is needed only once."),
    ("3", "Drop a song on the window. STEMEKI needs Demucs 4 (Python) on this Mac."),
]
var top: CGFloat = 288
for (i, (number, body)) in steps.enumerated() {
    let badge = NSRect(x: 52, y: y(top) - 22, width: 22, height: 22)
    stems[i].setFill(); NSBezierPath(ovalIn: badge).fill()
    text(number, .systemFont(ofSize: 12, weight: .bold), .black, centerX: badge.midX, top: top + 3.5)
    text(body, .systemFont(ofSize: 13), rgb(0.88, 0.89, 0.93), x: 88, top: top + 2, width: W - 140)
    top += body.contains("\n") ? 70 : 34
}
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
