import SwiftUI
import AVFoundation

/// Start-up splash in the EKIDIO SOUND style (as PADEKI): "STEM" slides in, four stem-coloured bands
/// fly together into the "EKI" badge and light up one after another with a little jingle.
struct SplashView: View {
    let onDone: () -> Void
    @State private var start = Date()
    @State private var leaving = false
    @State private var jingle: AVAudioPlayer?

    static let total: Double = 2.6
    private let colors = [Theme.vocals, Theme.drums, Theme.bass, Theme.other]

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSince(start)
            Canvas { ctx, size in draw(ctx, size, t) }
        }
        .background(background)
        .opacity(leaving ? 0 : 1)
        .scaleEffect(leaving ? 1.04 : 1)
        .animation(.easeIn(duration: 0.5), value: leaving)
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .onAppear {
            start = Date()
            jingle = Self.makeJingle()
            jingle?.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.total) { finish() }
        }
    }

    private var background: some View {
        ZStack {
            Color(red: 0.043, green: 0.043, blue: 0.05)
            RadialGradient(colors: [Theme.other.opacity(0.22), Theme.vocals.opacity(0.08), .clear],
                           center: .init(x: 0.5, y: 0.47), startRadius: 0, endRadius: 520)
        }
        .ignoresSafeArea()
    }

    private func finish() {
        guard !leaving else { return }
        leaving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { onDone() }
    }

    // MARK: Drawing

    private func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    private func easeOut(_ x: Double) -> Double { 1 - pow(1 - clamp(x), 3) }
    private func overshoot(_ x: Double) -> Double {
        let c = clamp(x), s = 1.9
        return 1 + (s + 1) * pow(c - 1, 3) + s * pow(c - 1, 2)
    }

    func draw(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double) {
        let cx = size.width / 2, cy = size.height / 2 - 20
        let unit = min(size.width / 900, size.height / 640) * 1.0
        let skew = CGAffineTransform(a: 1, b: 0, c: -0.25, d: 1, tx: 0, ty: 0)

        // "STEM" slides in from the left.
        let sIn = easeOut(t / 0.6)
        var stemCtx = ctx
        stemCtx.opacity = sIn
        // The logo is centred as a whole: "STEM" ends just left of the middle, the badge starts right of it.
        stemCtx.translateBy(x: cx + 6 * unit - (1 - sIn) * 80, y: cy)
        stemCtx.draw(Text("STEM").font(.system(size: 120 * unit, weight: .black).italic()).foregroundColor(.white),
                     at: .zero, anchor: .trailing)

        // The EKI badge: four bands flying together, then flashing one by one.
        let bw = 300 * unit, bh = 150 * unit
        let bx = cx + 34 * unit - bh / 2 * 0.25, by = cy - bh / 2
        let landed = clamp((t - 0.95) / 0.1)
        // White offset shadow once the bands are in.
        if landed > 0 {
            var sh = ctx
            sh.opacity = landed
            sh.translateBy(x: bx + 12 * unit + bh / 2 * 0.25, y: by + 12 * unit)
            sh.concatenate(skew)
            sh.fill(Path(CGRect(x: 0, y: 0, width: bw, height: bh)), with: .color(.white))
        }
        let from: [CGSize] = [CGSize(width: -1.6, height: -2.4), CGSize(width: 2.2, height: -1.2),
                              CGSize(width: -2.4, height: 1.4), CGSize(width: 1.8, height: 2.6)]
        for i in 0..<4 {
            let p = easeOut((t - 0.25 - Double(i) * 0.1) / 0.6)
            guard p > 0 else { continue }
            let flash = max(0, 1 - abs(t - (1.15 + Double(i) * 0.1)) / 0.12)
            var b = ctx
            b.opacity = min(1, p * 1.4)
            let ox = from[i].width * bw * (1 - p), oy = from[i].height * bh * (1 - p)
            b.translateBy(x: bx + bh / 2 * 0.25 + ox, y: by + CGFloat(i) * bh / 4 + oy)
            b.rotate(by: .degrees(Double(i % 2 == 0 ? -1 : 1) * 25 * (1 - p)))
            b.concatenate(skew)
            let rect = CGRect(x: 0, y: 0, width: bw, height: bh / 4 + 0.5)
            b.fill(Path(rect), with: .color(colors[i]))
            if flash > 0 { b.fill(Path(rect), with: .color(.white.opacity(0.55 * flash))) }
        }
        // "EKI" pops in over the bands.
        let ePop = overshoot((t - 1.25) / 0.4)
        if t > 1.25 {
            var e = ctx
            e.translateBy(x: bx + bw / 2 + 10 * unit, y: by + bh / 2 + 4 * unit)
            e.scaleBy(x: ePop, y: ePop)
            e.draw(Text("EKI").font(.system(size: 116 * unit, weight: .black).italic()).foregroundColor(.white),
                   at: .zero, anchor: .center)
        }

        // A four-colour line grows, then the subtitle.
        let lg = easeOut((t - 1.35) / 0.6)
        if lg > 0 {
            let lw = 620 * unit * lg, ly = cy + bh / 2 + 46 * unit
            let rect = CGRect(x: cx - lw / 2, y: ly, width: lw, height: 4 * unit)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 2),
                     with: .linearGradient(Gradient(colors: [.clear] + colors + [.clear]),
                                           startPoint: CGPoint(x: rect.minX, y: ly), endPoint: CGPoint(x: rect.maxX, y: ly)))
        }
        let sub = easeOut((t - 1.6) / 0.5)
        if sub > 0 {
            var s = ctx
            s.opacity = sub
            s.draw(Text("S T E M S   ·   L O O P S   ·   R E M I X")
                    .font(.system(size: 15 * unit, weight: .bold, design: .monospaced)).foregroundColor(Color(white: 0.85)),
                   at: CGPoint(x: cx, y: cy + bh / 2 + 82 * unit + (1 - sub) * 8))
        }
        // Brand and version at the bottom.
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        var v = ctx
        v.opacity = easeOut((t - 1.0) / 0.6)
        v.draw(Text("V\(ver) · EKIDIO SOUND").font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Color(white: 0.4)),
               at: CGPoint(x: size.width / 2, y: size.height - 26))
    }

    // MARK: Jingle

    /// A soft "pling" as each band flashes, then a small sparkle chord. Rendered to memory and played once.
    static func makeJingle() -> AVAudioPlayer? {
        let sr = 44100.0, dur = 2.4
        let n = Int(sr * dur)
        var buf = [Float](repeating: 0, count: n)
        func mtof(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }
        func pling(_ at: Double, _ note: Double, _ lvl: Float, _ len: Double) {
            let f = mtof(note), s = Int(at * sr), e = min(n, s + Int(len * sr))
            for i in s..<e {
                let x = Double(i - s) / sr
                let env = exp(-x * 9 / len) * min(1, x / 0.004)
                let v = sin(2 * .pi * f * x) + 0.18 * sin(4 * .pi * f * x) * exp(-x * 20) + 0.06 * sin(2 * .pi * f * 3.01 * x)
                buf[i] += lvl * Float(env * v)
            }
        }
        for (i, note) in [76.0, 79, 83, 88].enumerated() { pling(1.15 + Double(i) * 0.1, note, 0.16, 0.35) }
        for (k, note) in [84.0, 88, 91, 96].enumerated() { pling(1.62 + Double(k) * 0.035, note, 0.08, 0.9) }
        // 16-bit WAV in memory.
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * 2)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sr)); u32(UInt32(sr) * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 2))
        for v in buf { u16(UInt16(bitPattern: Int16(max(-1, min(1, v)) * 32000))) }
        let p = try? AVAudioPlayer(data: data)
        p?.volume = 0.5
        return p
    }
}
