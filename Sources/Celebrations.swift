import SwiftUI

/// Small, short moments of joy when something worked: a song separated, files exported, a project saved,
/// the loop taken from a selection. They never block anything and need no click.
@MainActor
final class Celebrate: ObservableObject {
    static let shared = Celebrate()

    /// A song just came out of the separation (its lanes sweep in, its row shimmers).
    @Published private(set) var separated: (id: UUID, n: Int)?
    /// Files just exported: one little card per file, in its stem's colour.
    @Published private(set) var exported: (colors: [Color], n: Int)?
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
        exported = (Array(colors), count)
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
