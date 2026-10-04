import SwiftUI
import AVFoundation

/// Shown while a song is being separated and analysed: the real song waveform right away (and a
/// preview player), with an animated "splitting into stems" scene that follows the real progress.
struct ProcessingView: View {
    @EnvironmentObject var library: Library
    let song: Song
    @StateObject private var preview = SourcePreview()

    var body: some View {
        let p = library.progress[song.id] ?? (song.state == .analyzing ? 0.95 : 0)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Button { preview.toggle() } label: {
                    Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold)).foregroundColor(.black)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(preview.isPlaying ? Theme.loop : Theme.text))
                }
                .buttonStyle(.plain)
                .disabled(preview.duration == 0)
                .help("Listen while it is being prepared")
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title).font(.system(size: 19, weight: .bold)).lineLimit(1)
                    Text(song.state == .failed ? "Something went wrong" : stage(p, song.state))
                        .font(.system(size: 12, weight: .medium)).foregroundColor(Theme.dim)
                        .animation(.easeInOut(duration: 0.3), value: stage(p, song.state))
                }
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)

            // The full song, as one waveform, with a scan line at the progress point.
            ZStack {
                if let peaks = preview.peaks {
                    TimelineCanvas(lanes: [.full], audible: ["mix": true], peaks: [:], mixPeaks: peaks, grid: nil,
                                   loopRange: nil, loopOn: false, loopLabel: nil, drumStart: nil,
                                   regions: [], selected: [], clips: [], segs: [:],
                                   viewStart: 0, viewLength: max(preview.duration, 0.1))
                    ScanLine(progress: p, playhead: preview.duration > 0 ? preview.position / preview.duration : nil)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
            .padding(.horizontal, 14)

            // The splitting scene.
            Group {
                if song.state == .failed {
                    VStack(spacing: 10) {
                        Text(song.error ?? "Error").foregroundColor(.red).font(.system(size: 12)).multilineTextAlignment(.center)
                        Button("Retry") { library.retry(song.id) }.buttonStyle(PillButtonStyle(color: Theme.accent, filled: true))
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    StemSplitAnimation(progress: p, waiting: song.state == .queued)
                }
            }
            .frame(height: 230)
            .padding(14)
        }
        .onAppear { preview.load(URL(fileURLWithPath: song.sourcePath)) }
        .onChange(of: song.id) { _, _ in preview.load(URL(fileURLWithPath: song.sourcePath)) }
        .onDisappear { preview.stop() }
    }

    private func stage(_ p: Double, _ state: SongState) -> String {
        if state == .queued { return "Waiting for its turn…" }
        if state == .analyzing || p >= 0.9 { return "Locking the beat grid…" }
        switch p {
        case ..<0.06: return "Listening to the song…"
        case ..<0.30: return "Finding the vocals…"
        case ..<0.55: return "Pulling out the drums…"
        case ..<0.75: return "Isolating the bass…"
        default: return "Separating the instruments…"
        }
    }
}

/// Glowing line sweeping the waveform at the processing point (plus the preview playhead).
private struct ScanLine: View {
    let progress: Double
    let playhead: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = CGFloat(min(1, max(0, progress))) * w
            ZStack(alignment: .topLeading) {
                // Already processed part: a soft colour wash.
                LinearGradient(colors: [Theme.vocals, Theme.drums, Theme.bass, Theme.other].map { $0.opacity(0.10) },
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: x)
                    .animation(.easeOut(duration: 0.6), value: progress)
                Rectangle()
                    .fill(LinearGradient(colors: [.clear, Theme.accent.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 40)
                    .offset(x: x - 20)
                    .animation(.easeOut(duration: 0.6), value: progress)
                Rectangle().fill(Theme.accent).frame(width: 2)
                    .offset(x: x - 1)
                    .shadow(color: Theme.accent, radius: 6)
                    .animation(.easeOut(duration: 0.6), value: progress)
                if let ph = playhead {
                    Rectangle().fill(Color.white).frame(width: 1.5).offset(x: CGFloat(ph) * w)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// A white "mix" wave that splits into four coloured stem waves as the work goes on.
private struct StemSplitAnimation: View {
    let progress: Double
    let waiting: Bool

    private let stems: [(String, Color)] = [("VOCALS", Theme.vocals), ("DRUMS", Theme.drums),
                                            ("BASS", Theme.bass), ("INSTRUMENTS", Theme.other)]

    var body: some View {
        TimelineView(.animation) { tl in
            let time = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                draw(ctx, size, time)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
        .overlay(alignment: .bottomTrailing) {
            Text("\(Int(min(1, progress) * 100))%")
                .font(Theme.mono(22, .bold)).foregroundColor(Theme.text.opacity(0.85))
                .padding(14)
                .animation(.default, value: Int(progress * 100))
        }
    }

    private func ease(_ x: Double) -> Double {
        let c = min(1, max(0, x))
        return c * c * (3 - 2 * c)
    }

    /// Each stem's own motion: vocals smooth, drums spiky, bass slow and deep, instruments busy.
    private func wave(_ i: Int, _ u: Double, _ t: Double) -> Double {
        switch i {
        case 0: return sin(u * 9 + t * 2.1) * 0.55 + sin(u * 23 + t * 3.3) * 0.25
        case 1:
            let beat = (u * 8 + t * 1.6).truncatingRemainder(dividingBy: 1)
            return exp(-beat * 9) * sin(u * 140) * 1.1
        case 2: return sin(u * 4 + t * 1.2) * 0.85
        default: return sin(u * 31 + t * 4) * 0.35 + sin(u * 13 - t * 2.4) * 0.35
        }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double) {
        let w = size.width, h = size.height
        let left: CGFloat = 130, right: CGFloat = 90
        let span = w - left - right
        let mid = h / 2
        // Waiting: a calm idle mix. Working: the stems fan out over the first ~60% of the progress.
        let split = waiting ? 0.0 : ease(0.25 + progress / 0.45)
        let lanes = stems.count
        let spacing = (h - 40) / CGFloat(lanes)

        // Source mix on the left.
        ctx.draw(Text("MIX").font(.system(size: 11, weight: .heavy)).foregroundColor(Theme.text), at: CGPoint(x: 28, y: mid), anchor: .leading)

        for (i, (name, color)) in stems.enumerated() {
            let target = 20 + spacing * (CGFloat(i) + 0.5)
            var centre = Path(), top: [CGPoint] = [], bottom: [CGPoint] = []
            let steps = 260
            for k in 0...steps {
                let u = Double(k) / Double(steps)
                let x = left + CGFloat(u) * span
                // Along the line the strand moves from the shared mix centre to its own lane.
                let along = ease((u - 0.04) / 0.45)
                let y0 = mid + (target - mid) * CGFloat(split * along)
                let v = wave(i, u, t)
                let mixWobble = sin(u * 17 + t * 2.6) * (1 - split * along)
                let cy = y0 + CGFloat(mixWobble * 4)
                // Thickness: a waveform-like envelope that grows as the stem comes free.
                let thick = CGFloat(2 + (spacing * 0.42) * CGFloat(split * along) * CGFloat(abs(v)))
                top.append(CGPoint(x: x, y: cy - thick))
                bottom.append(CGPoint(x: x, y: cy + thick))
                if k == 0 { centre.move(to: CGPoint(x: x, y: cy)) } else { centre.addLine(to: CGPoint(x: x, y: cy)) }
            }
            var band = Path()
            band.move(to: top[0])
            for pt in top.dropFirst() { band.addLine(to: pt) }
            for pt in bottom.reversed() { band.addLine(to: pt) }
            band.closeSubpath()
            let a = 0.3 + 0.7 * split
            let col = split < 0.02 ? Color.white : color
            var glow = ctx
            glow.addFilter(.blur(radius: 8))
            glow.fill(band, with: .color(col.opacity(0.35 * a)))
            ctx.fill(band, with: .color(col.opacity(0.55 * a)))
            ctx.stroke(centre, with: .color(col.opacity(a)), lineWidth: 1.2)

            // Labels appear as each stem comes free (one after another).
            let reveal = ease((progress - 0.04 - Double(i) * 0.16) / 0.1)
            if !waiting && reveal > 0 {
                var label = ctx
                label.opacity = reveal
                label.draw(Text(name).font(.system(size: 10.5, weight: .heavy)).foregroundColor(color),
                           at: CGPoint(x: w - right + 12, y: target), anchor: .leading)
            }
        }
    }
}

/// Peaks and a simple player for the original file, available before any stem exists.
@MainActor
final class SourcePreview: ObservableObject {
    @Published private(set) var peaks: StemPeaks?
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    private var player: AVAudioPlayer?
    private var url: URL?
    private var timer: Timer?

    func load(_ u: URL) {
        guard u != url else { return }
        stop()
        url = u
        peaks = nil
        player = try? AVAudioPlayer(contentsOf: u)
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        Task.detached(priority: .userInitiated) {
            let p = StemPeaks.compute(url: u)
            await MainActor.run { [weak self] in
                guard let self, self.url == u else { return }
                self.peaks = p
            }
        }
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            timer?.invalidate()
        } else {
            player.play()
            isPlaying = true
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let p = self.player else { return }
                    self.position = p.currentTime
                    if !p.isPlaying { self.isPlaying = false; self.timer?.invalidate() }
                }
            }
        }
    }

    func stop() {
        player?.stop()
        isPlaying = false
        timer?.invalidate()
    }
}
