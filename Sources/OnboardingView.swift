import SwiftUI

/// First-run intro: four short cards with small animated pictures. Reopened with the "?" button.
struct OnboardingView: View {
    let onDone: () -> Void
    @State private var page: Int

    init(startPage: Int = 0, onDone: @escaping () -> Void) {
        self.onDone = onDone
        _page = State(initialValue: startPage)
    }
    private let colors = [Theme.vocals, Theme.drums, Theme.bass, Theme.other]

    private struct Card {
        let step: String, title: String, text: String, keys: String
    }
    private let cards: [Card] = [
        Card(step: "1", title: "Drop a song",
             text: "It starts playing at once while the AI splits it into vocals, drums, bass and instruments, and locks it to the bar grid.",
             keys: "drag & drop · ⌘O"),
        Card(step: "2", title: "CUE = bar 1",
             text: "The CUE lands on the very first hit AUTO WARP pins. Hear the “one” somewhere else? Press C at the playhead or drag the flag.",
             keys: "C · drag the CUE flag"),
        Card(step: "3", title: "Rebuild the song",
             text: "EDIT: drag to select, click to cut, D to duplicate, drag pieces around or trim their edges. A mini DAW for the song's structure.",
             keys: "click = cut · D · ⌫ · ⌘Z"),
        Card(step: "4", title: "Export DAW-ready loops",
             text: "FULL stems, stems FROM the CUE, the LOOP, or every REGION on its own — bar-exact, on a whole BPM, ready for any DAW.",
             keys: "E = EDIT / EXPORT · ⌘E · ⇧⌘E"),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea().onTapGesture {}
            VStack(spacing: 0) {
                TimelineView(.animation) { tl in
                    Canvas { ctx, size in
                        picture(page, ctx, size, tl.date.timeIntervalSinceReferenceDate)
                    }
                }
                .frame(height: 210)
                .background(Theme.bg)
                .id(page)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("STEP \(cards[page].step) / 4").font(Theme.mono(10.5, .bold)).foregroundColor(Theme.accent)
                        Spacer()
                        Text(cards[page].keys).font(Theme.mono(10, .semibold)).foregroundColor(Theme.dim)
                    }
                    Text(cards[page].title).font(.system(size: 24, weight: .heavy)).foregroundColor(.white)
                    Text(cards[page].text).font(.system(size: 13.5)).foregroundColor(Theme.text.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(22)

                HStack {
                    Button("Skip") { onDone() }.buttonStyle(.plain).foregroundColor(Theme.dim)
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach(0..<4) { i in
                            Capsule().fill(i == page ? colors[i] : Color.white.opacity(0.15))
                                .frame(width: i == page ? 22 : 8, height: 8)
                        }
                    }
                    .animation(.spring(response: 0.35), value: page)
                    Spacer()
                    if page > 0 {
                        Button("Back") { withAnimation { page -= 1 } }.buttonStyle(PillButtonStyle(small: true))
                    }
                    Button(page == 3 ? "Let's go" : "Next") {
                        if page == 3 { onDone() } else { withAnimation { page += 1 } }
                    }
                    .buttonStyle(PillButtonStyle(color: Theme.accent, filled: true))
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 22).padding(.bottom, 20)
            }
            .frame(width: 560)
            .background(RoundedRectangle(cornerRadius: 18).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.08)))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.6), radius: 40, y: 12)
        }
    }

    // MARK: Pictures

    private func ease(_ x: Double) -> Double { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }

    private func wave(_ ctx: GraphicsContext, _ r: CGRect, _ color: Color, _ seed: Double, _ t: Double, amp: CGFloat = 1) {
        var p = Path()
        let n = 90
        for k in 0...n {
            let u = Double(k) / Double(n)
            let v = abs(sin(u * 37 + seed) * cos(u * 11 + seed * 2)) * (0.4 + 0.6 * abs(sin(u * 5 + t * 0.6 + seed)))
            let h = CGFloat(v) * r.height / 2 * amp
            let x = r.minX + CGFloat(u) * r.width
            p.addRect(CGRect(x: x, y: r.midY - h, width: max(1, r.width / CGFloat(n) - 1), height: max(1, h * 2)))
        }
        ctx.fill(p, with: .color(color))
    }

    private func picture(_ page: Int, _ ctx: GraphicsContext, _ size: CGSize, _ time: Double) {
        let w = size.width, h = size.height
        let t = time.truncatingRemainder(dividingBy: 4)          // every picture loops every 4 s
        switch page {
        case 0:
            // A mix wave splits into four stem lanes.
            let split = ease((t - 0.6) / 1.4)
            let laneH = (h - 50) / 4
            for i in 0..<4 {
                let y = 25 + CGFloat(i) * laneH
                let mixY = h / 2 - laneH / 2
                let r = CGRect(x: 60, y: mixY + (y - mixY) * CGFloat(split), width: w - 120, height: laneH - 6)
                let c = split < 0.05 ? Color(white: 0.8) : colors[i]
                wave(ctx, r, c.opacity(0.35 + 0.65 * split), Double(i) * 1.7, time, amp: split < 0.05 ? 1.3 : 1)
            }
        case 1:
            // A drum lane with a CUE flag jumping onto the beat.
            let r = CGRect(x: 40, y: 70, width: w - 80, height: 90)
            for k in 0..<17 {
                let x = r.minX + CGFloat(k) * r.width / 16
                ctx.fill(Path(CGRect(x: x, y: 40, width: 1, height: h - 60)), with: .color(.white.opacity(k % 4 == 0 ? 0.18 : 0.06)))
                var hit = Path()
                hit.addRect(CGRect(x: x, y: r.midY - (k % 4 == 0 ? 38 : 22), width: 4, height: k % 4 == 0 ? 76 : 44))
                ctx.fill(hit, with: .color(Theme.drums.opacity(0.9)))
            }
            let target = r.minX + 4 * r.width / 16
            let start = r.minX + 1.4 * r.width / 16
            let fx = start + (target - start) * CGFloat(ease((t - 1) / 0.5))
            ctx.fill(Path(CGRect(x: fx - 1, y: 40, width: 2, height: h - 60)), with: .color(Theme.accent))
            let flag = CGRect(x: fx - 30, y: 26, width: 28, height: 14)
            ctx.fill(Path(roundedRect: flag, cornerRadius: 3), with: .color(Theme.accent))
            ctx.draw(Text("CUE").font(Theme.mono(9, .heavy)).foregroundColor(.black), at: CGPoint(x: flag.midX, y: flag.midY))
            ctx.draw(Text("1").font(Theme.mono(13, .heavy)).foregroundColor(.white), at: CGPoint(x: fx + 10, y: 33))
            if t > 0.8 && t < 1.4 {
                let key = CGRect(x: w / 2 - 22, y: h - 44, width: 44, height: 30)
                ctx.fill(Path(roundedRect: key, cornerRadius: 6), with: .color(.white))
                ctx.draw(Text("C").font(.system(size: 16, weight: .heavy)).foregroundColor(.black), at: CGPoint(x: key.midX, y: key.midY))
            }
        case 2:
            // A piece is cut out of a lane and its copy slides along (D).
            let lane = CGRect(x: 40, y: 60, width: w - 80, height: 90)
            let unit = lane.width / 8
            wave(ctx, CGRect(x: lane.minX, y: lane.minY, width: unit * 2, height: lane.height), Theme.bass, 1, time)
            wave(ctx, CGRect(x: lane.minX + unit * 4, y: lane.minY, width: unit * 4, height: lane.height), Theme.bass, 3, time)
            let piece = CGRect(x: lane.minX + unit * 2, y: lane.minY, width: unit * 2, height: lane.height)
            wave(ctx, piece, Theme.bass, 2, time)
            ctx.stroke(Path(roundedRect: piece, cornerRadius: 5), with: .color(.white), lineWidth: 2)
            let slide = ease((t - 1.2) / 0.8)
            if t > 1.0 {
                let copy = piece.offsetBy(dx: unit * 2 * CGFloat(slide) + (t > 2.2 ? unit * 2 * CGFloat(ease((t - 2.4) / 0.8)) : 0), dy: 0)
                var c = ctx
                c.opacity = 0.95
                c.fill(Path(roundedRect: copy, cornerRadius: 5), with: .color(Theme.panel2))
                wave(c, copy, Theme.bass, 2, time)
                c.stroke(Path(roundedRect: copy, cornerRadius: 5), with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
            let key = CGRect(x: w / 2 - 22, y: h - 44, width: 44, height: 30)
            if t > 0.8 && t < 1.4 {
                ctx.fill(Path(roundedRect: key, cornerRadius: 6), with: .color(.white))
                ctx.draw(Text("D").font(.system(size: 16, weight: .heavy)).foregroundColor(.black), at: CGPoint(x: key.midX, y: key.midY))
            }
        default:
            // Loops fly out as files.
            let labels = ["FULL", "FROM CUE", "LOOP", "REGION"]
            for i in 0..<4 {
                let p = ease((t - Double(i) * 0.35) / 0.9)
                let x0 = w / 2 - 20, y0 = h / 2 - 20
                let x1 = 60 + CGFloat(i) * (w - 160) / 3, y1: CGFloat = 46
                let r = CGRect(x: x0 + (x1 - x0) * CGFloat(p), y: y0 + (y1 - y0) * CGFloat(p), width: 70, height: 86)
                var c = ctx
                c.opacity = p
                c.fill(Path(roundedRect: r, cornerRadius: 8), with: .color(colors[i]))
                c.fill(Path(roundedRect: r.insetBy(dx: 10, dy: 30).offsetBy(dx: 0, dy: 6), cornerRadius: 2), with: .color(.white.opacity(0.35)))
                c.draw(Text("WAV").font(Theme.mono(10, .heavy)).foregroundColor(.black), at: CGPoint(x: r.midX, y: r.minY + 16))
                c.draw(Text(labels[i]).font(Theme.mono(10, .heavy)).foregroundColor(.white), at: CGPoint(x: r.midX, y: r.maxY + 12))
            }
            ctx.draw(Text("bar-exact · whole BPM · ACID loops").font(Theme.mono(11, .bold)).foregroundColor(Theme.dim),
                     at: CGPoint(x: w / 2, y: h - 22))
        }
    }
}
