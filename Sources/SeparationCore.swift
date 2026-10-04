import SwiftUI

/// The "magic" in the middle of the preparing screen: a glowing core with a circular waveform ring,
/// four orbiting stem tracks and the stem being pulled out right now. Follows the real progress.
struct SeparationCore: View {
    let progress: Double
    let state: SongState

    private let colors = StemekiLogo.bandColors
    private let names = ["VOCALS", "DRUMS", "BASS", "INSTRUMENTS"]

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle().fill(.ultraThinMaterial).frame(width: 190, height: 190)
                    .shadow(color: activeColor(t).opacity(0.55), radius: 40)
                Canvas { ctx, size in draw(ctx, size, t) }
                VStack(spacing: 4) {
                    Text(caption).font(.system(size: 10, weight: .heavy, design: .monospaced)).tracking(2.5)
                        .foregroundColor(.white.opacity(0.6))
                    Text(word(t)).font(.system(size: word(t).count > 8 ? 20 : 27, weight: .black).italic())
                        .foregroundColor(activeColor(t))
                        .shadow(color: activeColor(t).opacity(0.8), radius: 10)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.35), value: word(t))
                }
            }
        }
        .frame(width: 360, height: 360)
        .allowsHitTesting(false)
    }

    // MARK: What is happening

    private var step: Int { ProcessingView.stage(progress, state).step }

    private var caption: String {
        switch step {
        case 0: return "WAITING"
        case 5: return "LOCKING THE"
        case 4: return "REBUILDING"
        default: return "EXTRACTING"
        }
    }

    /// Index of the stem in focus right now (nil = all / the grid).
    private func active(_ t: Double) -> Int? {
        switch step {
        case 1: return Int(t / 0.7) % 4
        case 2: return Int(t / 1.3) % 2          // vocals, drums
        case 3: return 2 + Int(t / 1.3) % 2      // bass, instruments
        case 4: return Int(t / 0.5) % 4
        default: return nil
        }
    }

    private func word(_ t: Double) -> String {
        if step == 5 { return "BEAT GRID" }
        if step == 0 { return "IN LINE" }
        if step == 1 { return "STEMS" }
        return active(t).map { names[$0] } ?? "STEMS"
    }

    private func activeColor(_ t: Double) -> Color {
        if step == 5 || step == 0 { return Theme.accent }
        if step == 1 || step == 4 { return colors[Int(t / 0.7) % 4] }
        return active(t).map { colors[$0] } ?? Theme.accent
    }

    // MARK: Drawing

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let R: CGFloat = 96

        // Particles spiralling in.
        for k in 0..<36 {
            let seed = Double(k) * 1.618
            let life = (t * 0.45 + seed).truncatingRemainder(dividingBy: 1)   // 0 → 1 = outer → core
            let ang = seed * 2.4 + life * 2.2
            let r = CGFloat(1 - life) * (size.width * 0.5) + R * 0.95 * CGFloat(life)
            let p = CGPoint(x: c.x + cos(ang) * r, y: c.y + sin(ang) * r)
            let col = colors[k % 4]
            let a = sin(.pi * life)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)), with: .color(col.opacity(0.75 * a)))
        }

        // Circular waveform ring.
        let bars = 160
        for i in 0..<bars {
            let u = Double(i) / Double(bars)
            let ang = u * 2 * .pi + t * 0.25
            let v = abs(sin(u * 37 + t * 2.1) * cos(u * 13 - t * 1.3))
            let pulse = 0.65 + 0.35 * sin(t * 3)
            let len = CGFloat(4 + 24 * v * pulse)
            let p0 = CGPoint(x: c.x + cos(ang) * (R + 8), y: c.y + sin(ang) * (R + 8))
            let p1 = CGPoint(x: c.x + cos(ang) * (R + 8 + len), y: c.y + sin(ang) * (R + 8 + len))
            var line = Path(); line.move(to: p0); line.addLine(to: p1)
            let col = colors[min(3, Int(u * 4))]
            ctx.stroke(line, with: .color(col.opacity(0.85)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }

        // Four orbits with a bright dot and a trailing arc; the stem in focus is thicker.
        let focus = active(t)
        let speeds = [1.1, -0.8, 0.65, -1.35]
        for i in 0..<4 {
            let r = R - 16 - CGFloat(i) * 11
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(.white.opacity(0.06)), lineWidth: 1)
            let head = t * speeds[i] + Double(i) * 1.6
            let on = focus == nil || focus == i
            var arc = Path()
            arc.addArc(center: c, radius: r, startAngle: .radians(head - (speeds[i] > 0 ? 1.1 : -1.1)),
                       endAngle: .radians(head), clockwise: speeds[i] < 0)
            ctx.stroke(arc, with: .color(colors[i].opacity(on ? 0.95 : 0.3)),
                       style: StrokeStyle(lineWidth: on ? 3.5 : 1.5, lineCap: .round))
            let dp = CGPoint(x: c.x + cos(head) * r, y: c.y + sin(head) * r)
            var glow = ctx
            glow.addFilter(.blur(radius: 4))
            glow.fill(Path(ellipseIn: CGRect(x: dp.x - 6, y: dp.y - 6, width: 12, height: 12)), with: .color(colors[i].opacity(on ? 1 : 0.3)))
            ctx.fill(Path(ellipseIn: CGRect(x: dp.x - 3, y: dp.y - 3, width: 6, height: 6)), with: .color(.white.opacity(on ? 1 : 0.4)))
        }

        // Progress arc just outside the waveform ring.
        let pr = R + 40
        var track = Path()
        track.addArc(center: c, radius: pr, startAngle: .degrees(-90), endAngle: .degrees(270), clockwise: false)
        ctx.stroke(track, with: .color(.white.opacity(0.06)), lineWidth: 3)
        var done = Path()
        done.addArc(center: c, radius: pr, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * min(1, progress)), clockwise: false)
        ctx.stroke(done, with: .linearGradient(Gradient(colors: colors), startPoint: CGPoint(x: c.x - pr, y: c.y), endPoint: CGPoint(x: c.x + pr, y: c.y)),
                   style: StrokeStyle(lineWidth: 3, lineCap: .round))
    }
}
