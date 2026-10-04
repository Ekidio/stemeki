import SwiftUI

/// The STEMEKI logo: "STEM" in bold italic and the skewed EKI badge made of the four stem colours,
/// each band carrying a small waveform. `phase` moves the waveforms (0 = still).
struct StemekiLogo: View {
    var height: CGFloat = 30
    var phase: Double = 0

    var body: some View {
        Canvas { ctx, size in
            StemekiLogo.draw(ctx, CGRect(origin: .zero, size: size), phase: phase)
        }
        .frame(width: height * 3.55, height: height)
    }

    static let bandColors = [Theme.vocals, Theme.drums, Theme.bass, Theme.other]

    /// Draws the logo into `rect` (aspect ~3.55 : 1).
    static func draw(_ ctx: GraphicsContext, _ rect: CGRect, phase: Double, bandsOpacity: [Double] = [1, 1, 1, 1],
                     ekiScale: CGFloat = 1, stemOffset: CGFloat = 0, stemOpacity: Double = 1) {
        let h = rect.height
        let skew = CGAffineTransform(a: 1, b: 0, c: -0.25, d: 1, tx: 0, ty: 0)
        // "STEM"
        var s = ctx
        s.opacity = stemOpacity
        s.draw(Text("STEM").font(.system(size: h * 0.92, weight: .black).italic()).foregroundColor(.white),
               at: CGPoint(x: rect.minX + h * 1.72 + stemOffset, y: rect.midY + h * 0.02), anchor: .trailing)
        // Badge
        let bw = h * 1.62, bh = h * 0.86
        let bx = rect.minX + h * 1.86, by = rect.midY - bh / 2
        var sh = ctx
        sh.opacity = bandsOpacity.min() ?? 1
        sh.translateBy(x: bx + bh / 2 * 0.25 + h * 0.07, y: by + h * 0.07)
        sh.concatenate(skew)
        sh.fill(Path(CGRect(x: 0, y: 0, width: bw, height: bh)), with: .color(.white))
        for i in 0..<4 {
            var b = ctx
            b.opacity = bandsOpacity[i]
            b.translateBy(x: bx + bh / 2 * 0.25, y: by + CGFloat(i) * bh / 4)
            b.concatenate(skew)
            let band = CGRect(x: 0, y: 0, width: bw, height: bh / 4 + 0.4)
            b.fill(Path(band), with: .color(bandColors[i]))
            b.clip(to: Path(band))
            // The band's waveform.
            var wave = Path()
            let n = 26
            for k in 0..<n {
                let u = Double(k) / Double(n)
                let ph = u * 14 + Double(i) * 1.3 - phase * (1.6 + Double(i) * 0.35)
                let env = 0.25 + 0.75 * abs(sin(ph) * cos(ph * 0.37 + Double(i)))
                let wh = CGFloat(env) * bh / 8 * 0.85
                wave.addRect(CGRect(x: CGFloat(u) * bw, y: bh / 8 - wh, width: max(1, bw / CGFloat(n) * 0.55), height: wh * 2))
            }
            b.fill(wave, with: .color(.white.opacity(0.4)))
        }
        // "EKI"
        var e = ctx
        e.translateBy(x: bx + bw / 2 + h * 0.06, y: by + bh / 2 + h * 0.02)
        e.scaleBy(x: ekiScale, y: ekiScale)
        e.addFilter(.shadow(color: .black.opacity(0.35), radius: h * 0.03, x: h * 0.02, y: h * 0.03))
        e.draw(Text("EKI").font(.system(size: h * 0.8, weight: .black).italic()).foregroundColor(.white), at: .zero, anchor: .center)
    }
}
