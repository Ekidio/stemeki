// Renders the 1024×1024 app icon PNG. Usage: swift MakeIcon.swift <output.png>
import AppKit

let size = 1024
let output = CommandLine.arguments.dropFirst().first ?? "icon.png"

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 28
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(
    starting: NSColor(srgbRed: 0.09, green: 0.095, blue: 0.12, alpha: 1),
    ending: NSColor(srgbRed: 0.03, green: 0.03, blue: 0.04, alpha: 1)
)!.draw(in: shape, angle: -90)

// Four stem waveforms, one per color.
let colors: [NSColor] = [
    NSColor(srgbRed: 1.0, green: 0.36, blue: 0.54, alpha: 1),
    NSColor(srgbRed: 1.0, green: 0.66, blue: 0.13, alpha: 1),
    NSColor(srgbRed: 0.24, green: 0.86, blue: 0.59, alpha: 1),
    NSColor(srgbRed: 0.36, green: 0.66, blue: 1.0, alpha: 1),
]
let laneTop: CGFloat = 760, laneH: CGFloat = 112
for (i, c) in colors.enumerated() {
    let mid = laneTop - CGFloat(i) * (laneH + 22) - laneH / 2
    c.setFill()
    var x: CGFloat = 200
    var k = 0
    while x < 824 {
        let phase = Double(k) * 0.37 + Double(i) * 1.7
        let env = 0.35 + 0.65 * abs(sin(phase) * cos(phase * 0.53 + Double(i)))
        let h = CGFloat(env) * laneH * (i == 1 ? (k % 6 == 0 ? 1 : 0.35) : 0.9)
        NSBezierPath(roundedRect: NSRect(x: x, y: mid - h / 2, width: 10, height: h), xRadius: 5, yRadius: 5).fill()
        x += 16
        k += 1
    }
}

// Yellow loop frame across the middle.
let loopRect = NSRect(x: 420, y: 205, width: 236, height: 610)
NSColor(srgbRed: 1.0, green: 0.84, blue: 0.04, alpha: 0.13).setFill()
NSBezierPath(roundedRect: loopRect, xRadius: 18, yRadius: 18).fill()
NSColor(srgbRed: 1.0, green: 0.84, blue: 0.04, alpha: 1).setStroke()
let frame = NSBezierPath(roundedRect: loopRect, xRadius: 18, yRadius: 18)
frame.lineWidth = 14
frame.stroke()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
