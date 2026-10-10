import SwiftUI

/// Small, short moments of joy when something worked: a song separated, files exported, a project saved,
/// the loop taken from a selection. They never block anything and need no click.
@MainActor
final class Celebrate: ObservableObject {
    static let shared = Celebrate()

    /// A song just came out of the separation (its lanes sweep in, its row shimmers).
    @Published private(set) var separated: (id: UUID, n: Int)?
    /// Files just exported: one little card per file, in its stem's colour.
    @Published private(set) var exported: (colors: [Color], n: Int, files: Int)?
    /// U: the loop springs from where it was to the selection.
    @Published var loopSpring: LoopSpring?

    struct LoopSpring: Equatable {
        var from: ClosedRange<Double>
        var to: ClosedRange<Double>
        var n: Int
    }

    private var count = 0
    private var claimed: Set<String> = []

    /// Each moment plays once per place: a view coming back later does not replay it.
    func claim(_ n: Int, _ place: String) -> Bool { claimed.insert("\(place)#\(n)").inserted }

    func songSeparated(_ id: UUID) {
        count += 1
        separated = (id, count)
    }

    func filesExported(_ urls: [URL]) {
        count += 1
        let colors = urls.prefix(10).map { url -> Color in
            let name = url.deletingPathExtension().lastPathComponent.uppercased()
            // The lane tag in the file name ("_DRUMS_", "_VOCALS+BASS_") gives the colour; a mix is white.
            if name.contains("+") { return Theme.text }
            return Lane.all.first { name.contains("_\($0.fileTag)_") }?.color ?? Theme.bass
        }
        exported = (Array(colors), count, urls.count)
    }

    func loop(from: ClosedRange<Double>?, to: ClosedRange<Double>) {
        count += 1
        // No loop before: it grows out of the selection's middle.
        let mid = (to.lowerBound + to.upperBound) / 2
        loopSpring = LoopSpring(from: from ?? mid...mid, to: to, n: count)
    }

    /// The first export ever gets its own line, once.
    static func firstExport() -> Bool {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "firstExportDone") else { return false }
        d.set(true, forKey: "firstExportDone")
        return true
    }
}

// MARK: 1. Separation done: the song's row shimmers in the list

/// The song's row in the list: a light sweep across it when its stems are ready.
struct RowShimmer: ViewModifier {
    let songID: UUID
    @ObservedObject var celebrate = Celebrate.shared
    @State private var x: CGFloat = -1
    @State private var on = false

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { geo in
                if on {
                    LinearGradient(colors: [.clear, Color.white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.45)
                        .offset(x: x * geo.size.width)
                        .blendMode(.plusLighter)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .allowsHitTesting(false)
        }
        .onReceive(celebrate.$separated) { e in
            guard let e, e.id == songID, celebrate.claim(e.n, "row") else { return }
            x = -0.5; on = true
            withAnimation(.easeInOut(duration: 0.9)) { x = 1.1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { on = false }
        }
    }
}

// MARK: 2. Export done: the files drop into the EXPORT card

struct ExportBurst: View {
    @ObservedObject var celebrate = Celebrate.shared
    @State private var cards: [(Color, Int)] = []
    @State private var landed = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(cards.enumerated()), id: \.offset) { i, c in
                RoundedRectangle(cornerRadius: 3)
                    .fill(c.0)
                    .frame(width: 14, height: 18)
                    .overlay(Image(systemName: "waveform").font(.system(size: 7, weight: .bold)).foregroundColor(.black.opacity(0.6)))
                    .shadow(color: c.0.opacity(0.7), radius: 5)
                    .offset(y: landed ? 10 : -34)
                    .opacity(landed ? 0 : 1)
                    .animation(.spring(response: 0.45, dampingFraction: 0.62).delay(Double(i) * 0.06), value: landed)
            }
        }
        .allowsHitTesting(false)
        .onReceive(celebrate.$exported) { e in
            guard let e, celebrate.claim(e.n, "burst") else { return }
            landed = false
            cards = e.colors.map { ($0, e.n) }
            // Appear above the card, then fall in and vanish.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { landed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { if cards.first?.1 == e.n { cards = [] } }
        }
    }
}

// MARK: 2b. Export: a show in the middle of the window, from the start to the saved files

/// While an export runs: a glowing ring opens from the middle with the four stem colours pulsing in it.
/// When the files are saved: they fly out as cards in their colours, a tick draws itself in the ring with the
/// number of files, and it all fades away. Shown at least about a second, so a quick export is seen too.
struct ExportShow: View {
    @EnvironmentObject var session: Session
    @ObservedObject var celebrate = Celebrate.shared

    private enum Phase { case idle, working, done, failed }
    @State private var phase: Phase = .idle
    @State private var startedAt = Date()
    @State private var open = false          // the ring has opened
    @State private var tick: CGFloat = 0     // how much of the tick is drawn
    @State private var fly = false           // the file cards are out
    @State private var cards: [Color] = []
    @State private var files = 0
    @State private var label = ""
    @State private var token = 0

    private let stemColors = [Theme.vocals, Theme.drums, Theme.bass, Theme.other]

    var body: some View {
        ZStack {
            if phase != .idle {
                Color.black.opacity(open ? 0.45 : 0).ignoresSafeArea()
                ZStack {
                    // Cards flying out of the ring (one per file, in its stem's colour).
                    ForEach(Array(cards.enumerated()), id: \.offset) { i, c in
                        let a = Angle.degrees(-90 + (Double(i) - Double(cards.count - 1) / 2) * min(26, 200 / Double(max(cards.count, 1))))
                        RoundedRectangle(cornerRadius: 5)
                            .fill(c)
                            .frame(width: 34, height: 44)
                            .overlay(Image(systemName: "waveform").font(.system(size: 15, weight: .bold)).foregroundColor(.black.opacity(0.6)))
                            .shadow(color: c.opacity(0.8), radius: 10)
                            .rotationEffect(.degrees(fly ? (Double(i) - Double(cards.count - 1) / 2) * 9 : 0))
                            .offset(x: fly ? cos(a.radians) * 190 : 0, y: fly ? sin(a.radians) * 190 : 0)
                            .scaleEffect(fly ? 1 : 0.2)
                            .opacity(fly ? 1 : 0)
                            .animation(.spring(response: 0.55, dampingFraction: 0.6).delay(Double(i) * 0.05), value: fly)
                    }
                    ring
                }
                .scaleEffect(open ? 1 : 0.1)
                .opacity(open ? 1 : 0)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: session.exporting) { _, on in
            if on { start() } else { stopped() }
        }
        .onReceive(celebrate.$exported) { e in
            guard let e, phase == .working, celebrate.claim(e.n, "show") else { return }
            cards = Array(e.colors.prefix(12)); files = e.files
            // Let the working part be seen for a moment even when the export was quick.
            let wait = max(0, 1.1 - Date().timeIntervalSince(startedAt))
            let t = token
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { if t == token { finish() } }
        }
    }

    private var ring: some View {
        TimelineView(.animation) { ctx in
            let time = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle().fill(Theme.panel.opacity(0.96)).frame(width: 220, height: 220)
                    .shadow(color: (phase == .done ? Theme.bass : Theme.accent).opacity(0.45), radius: 40)
                // A comet running round while it works; a full green ring when done.
                if phase == .done {
                    Circle().stroke(Theme.bass, lineWidth: 5).frame(width: 220, height: 220)
                } else {
                    Circle().stroke(Theme.line, lineWidth: 5).frame(width: 220, height: 220)
                    Circle().trim(from: 0, to: 0.28)
                        .stroke(AngularGradient(colors: stemColors + [stemColors[0]], center: .center),
                                style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .frame(width: 220, height: 220)
                        .rotationEffect(.radians(time * 4.2))
                }
                VStack(spacing: 12) {
                    if phase == .done {
                        Tick().trim(from: 0, to: tick).stroke(Theme.bass, style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                            .frame(width: 70, height: 56)
                        Text("\(files) FILE\(files == 1 ? "" : "S") SAVED").font(.system(size: 13, weight: .heavy)).tracking(1.5)
                            .foregroundColor(.white)
                    } else {
                        // The four stems, pulsing like meters.
                        HStack(alignment: .center, spacing: 9) {
                            ForEach(0..<4, id: \.self) { i in
                                let v = 0.35 + 0.65 * abs(sin(time * (3.1 + Double(i) * 0.7) + Double(i) * 1.3))
                                RoundedRectangle(cornerRadius: 4).fill(stemColors[i])
                                    .frame(width: 16, height: 18 + 50 * v)
                                    .shadow(color: stemColors[i].opacity(0.7), radius: 6)
                            }
                        }
                        .frame(height: 70)
                        Text("EXPORTING").font(.system(size: 13, weight: .heavy)).tracking(2.5).foregroundColor(.white)
                    }
                    Text(phase == .done ? "into the folder you chose" : label)
                        .font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.dim)
                        .lineLimit(1).frame(maxWidth: 180)
                }
            }
        }
    }

    private func start() {
        token += 1
        phase = .working; startedAt = Date()
        label = session.exportLabel
        cards = []; fly = false; tick = 0; open = false
        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { open = true }
    }

    private func finish() {
        phase = .done
        withAnimation(.easeOut(duration: 0.45)) { tick = 1 }
        fly = true
        let t = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { if t == token { close() } }
    }

    /// The export ended: without saved files (an error) the show just closes; the message is in the toast.
    /// (The saved files are announced right after `exporting` goes off.)
    private func stopped() {
        let t = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if t == token, phase == .working, cards.isEmpty { close() }
        }
    }

    private func close() {
        let t = token
        withAnimation(.easeIn(duration: 0.45)) { open = false; fly = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if t == token { phase = .idle; cards = [] } }
    }
}

/// A tick mark, drawn from its short end.
struct Tick: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY + r.height * 0.05))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.36, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}

// MARK: 3. Saved: the unsaved dot turns into a tick

/// Rotates and grows in (used for the saved tick).
struct SpinIn: ViewModifier {
    let angle: Double
    let scale: CGFloat
    func body(content: Content) -> some View { content.rotationEffect(.degrees(angle)).scaleEffect(scale) }
}

extension AnyTransition {
    static var spinIn: AnyTransition {
        .asymmetric(insertion: .modifier(active: SpinIn(angle: -200, scale: 0.2), identity: SpinIn(angle: 0, scale: 1))
                        .combined(with: .opacity),
                    removal: .opacity)
    }
}

// MARK: 6. U: the loop springs to the selection's edges

/// Draws the loop band in the ruler while it springs (the timeline hides its own band meanwhile).
struct LoopSpringOverlay: View {
    let viewStart: Double
    let viewLength: Double
    let loopOn: Bool
    @ObservedObject var celebrate = Celebrate.shared
    @State private var range: ClosedRange<Double> = 0...0
    @State private var glow = 0.0

    var body: some View {
        GeometryReader { geo in
            if celebrate.loopSpring != nil {
                let w = geo.size.width
                let x0 = CGFloat((range.lowerBound - viewStart) / viewLength) * w
                let x1 = CGFloat((range.upperBound - viewStart) / viewLength) * w
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.loop.opacity(loopOn ? 0.9 : 0.35))
                    .frame(width: max(2, x1 - x0), height: rulerHeight - loopBandTop - 3)
                    .shadow(color: Theme.loop.opacity(glow), radius: 8)
                    .offset(x: x0, y: loopBandTop)
            }
        }
        .allowsHitTesting(false)
        .onReceive(celebrate.$loopSpring) { s in
            guard let s else { return }
            range = s.from
            glow = 0.9
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.5)) { range = s.to }
                withAnimation(.easeOut(duration: 0.7)) { glow = 0 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                if celebrate.loopSpring?.n == s.n { celebrate.loopSpring = nil }
            }
        }
    }
}
