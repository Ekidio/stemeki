import Foundation
import AVFoundation

/// Multi-resolution signed waveform of a stem (mono mid), for drawing and metering.
struct StemPeaks: Sendable {
    struct Level: Sendable {
        var binSize: Int
        var mins: [Float]
        var maxs: [Float]
        var rms: [Float]
    }

    static let baseBin = 32
    var levels: [Level]          // finest first: 32, 256, 2048, 16384 samples per bin
    var sampleRate: Double
    var maxPeak: Float

    /// The coarsest level that still has at least one bin per drawn column.
    func level(samplesPerColumn: Double) -> Level {
        var best = levels[0]
        for l in levels where Double(l.binSize) <= samplesPerColumn { best = l }
        return best
    }

    static func compute(url: URL) -> StemPeaks? { compute(urls: [url]) }

    /// Peaks of one file, or of several summed sample by sample (the stems together = the mix).
    static func compute(urls: [URL]) -> StemPeaks? {
        let files = urls.compactMap { try? AVAudioFile(forReading: $0) }
        guard let file = files.first, files.count == urls.count else { return nil }
        let chunk: AVAudioFrameCount = 65536
        let bufs = files.compactMap { AVAudioPCMBuffer(pcmFormat: $0.processingFormat, frameCapacity: chunk) }
        guard bufs.count == files.count, let buf = bufs.first else { return nil }
        let channels = Int(file.processingFormat.channelCount)
        let cap = Int(file.length) / baseBin + 1
        var mins: [Float] = [], maxs: [Float] = [], rms: [Float] = []
        mins.reserveCapacity(cap); maxs.reserveCapacity(cap); rms.reserveCapacity(cap)
        var lo: Float = .infinity, hi: Float = -.infinity, sq: Float = 0, n = 0
        var maxPeak: Float = 0
        while file.framePosition < file.length {
            var len = Int.max
            for (f, b) in zip(files, bufs) {
                do { try f.read(into: b, frameCount: chunk) } catch { len = 0 }
                len = min(len, Int(b.frameLength))
            }
            if len == 0 || len == Int.max { break }
            let datas = bufs.compactMap { $0.floatChannelData }
            guard datas.count == bufs.count else { break }
            _ = buf
            for i in 0..<len {
                var v: Float = 0
                for data in datas { for c in 0..<channels { v += data[c][i] } }
                v /= Float(channels)
                lo = min(lo, v); hi = max(hi, v); sq += v * v; n += 1
                if n == baseBin {
                    mins.append(lo); maxs.append(hi); rms.append((sq / Float(n)).squareRoot())
                    maxPeak = max(maxPeak, max(-lo, hi))
                    lo = .infinity; hi = -.infinity; sq = 0; n = 0
                }
            }
        }
        if n > 0 { mins.append(lo); maxs.append(hi); rms.append((sq / Float(n)).squareRoot()) }
        var levels = [Level(binSize: baseBin, mins: mins, maxs: maxs, rms: rms)]
        // Coarser levels, 8x each, so drawing a whole song stays cheap.
        while levels.count < 4 {
            let prev = levels[levels.count - 1]
            let count = (prev.mins.count + 7) / 8
            var m = [Float](repeating: 0, count: count), x = m, r = m
            for b in 0..<count {
                let a = b * 8, e = min(a + 8, prev.mins.count)
                var l: Float = .infinity, h: Float = -.infinity, s: Float = 0
                for j in a..<e { l = min(l, prev.mins[j]); h = max(h, prev.maxs[j]); s += prev.rms[j] * prev.rms[j] }
                m[b] = l; x[b] = h; r[b] = (s / Float(e - a)).squareRoot()
            }
            levels.append(Level(binSize: prev.binSize * 8, mins: m, maxs: x, rms: r))
        }
        return StemPeaks(levels: levels, sampleRate: file.processingFormat.sampleRate, maxPeak: maxPeak)
    }

    /// Short-term level at t, for the meters.
    func rmsAt(_ t: Double) -> Float {
        let l = levels[1]
        let i = Int(t * sampleRate) / l.binSize
        guard i >= 0, i < l.rms.count else { return 0 }
        var m: Float = 0
        for k in max(0, i - 4)..<min(l.rms.count, i + 4) { m = max(m, l.rms[k]) }
        return m * 1.4
    }
}

/// Sample-accurate transient times of a stem (seconds), for snapping the grid to real hits.
enum Onsets {
    struct Hits: Sendable {
        var times: [Double] = []
        var weights: [Float] = []
    }

    static func compute(url: URL) -> Hits {
        guard let file = try? AVAudioFile(forReading: url) else { return Hits() }
        let sr = file.processingFormat.sampleRate
        let ch = Int(file.processingFormat.channelCount)
        let win = 64, hop = 16
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return Hits() }
        // Short-window log energy of the mono signal.
        var energy: [Float] = []
        energy.reserveCapacity(Int(file.length) / hop + 1)
        var ring = [Float](repeating: 0, count: win)
        var ringSum: Float = 0
        var idx = 0, n = 0
        while file.framePosition < file.length {
            do { try file.read(into: buf, frameCount: chunk) } catch { break }
            let len = Int(buf.frameLength)
            if len == 0 { break }
            guard let d = buf.floatChannelData else { break }
            for i in 0..<len {
                var v: Float = 0
                for c in 0..<ch { v += d[c][i] }
                v /= Float(ch)
                let sq = v * v
                ringSum += sq - ring[idx]
                ring[idx] = sq
                idx = (idx + 1) % win
                n += 1
                if n % hop == 0 { energy.append(log10(max(ringSum / Float(min(n, win)), 1e-10))) }
            }
        }
        guard energy.count > 80, let top = energy.max() else { return Hits() }
        let floor = top - 4.5     // ignore anything 45 dB under the loudest part
        // Detection on a smoothed envelope (~23 ms), so the cycles of a deep kick are not separate hits.
        let smooth = 64
        var lin = energy.map { pow(10, $0) }
        var acc: Float = 0
        var longE = [Float](repeating: -10, count: energy.count)
        for i in 0..<lin.count {
            acc += lin[i]
            if i >= smooth { acc -= lin[i - smooth] }
            longE[i] = log10(max(acc / Float(min(i + 1, smooth)), 1e-10))
        }
        lin = []
        let lagL = 24             // ~9 ms rise on the smooth envelope
        let lagS = 4              // ~1.5 ms rise on the short one
        let minGap = Int(0.06 * sr) / hop
        var result: [Double] = []
        var weights: [Float] = []
        var i = lagL
        while i < longE.count - 1 {
            let rise = longE[i] - longE[i - lagL]
            if rise > 0.3, longE[i] > floor {
                // Peak of this rise on the smooth envelope.
                var peak = i, peakRise = rise
                var j = i + 1
                while j < min(longE.count, i + minGap) {
                    let r = longE[j] - longE[j - lagL]
                    if r > peakRise { peak = j; peakRise = r }
                    if r < peakRise * 0.5 { break }
                    j += 1
                }
                // Exact attack: the first steep step of the short envelope in the ~30 ms before the peak.
                let lo = max(lagS, peak - 80), hi = min(energy.count - 1, peak + 4)
                var maxS: Float = 0
                // Only where the signal is already part of the hit: in near-silence the log energy jitters.
                let audible = longE[peak] - 2.5
                for k in lo...hi where energy[k] > audible { maxS = max(maxS, energy[k] - energy[k - lagS]) }
                var at = peak
                for k in lo...hi where energy[k] > audible && energy[k] - energy[k - lagS] >= maxS * 0.6 { at = k; break }
                // Back to where the hit becomes audible (~26 dB under its peak), at most 15 ms earlier:
                // the ear hears the hit from there, so the grid, the click and loop starts belong there.
                let hitTop = energy[at...min(energy.count - 1, at + 80)].max() ?? energy[at]
                let startLevel = max(floor, hitTop - 2.6)
                let back = max(lagS, at - Int(0.015 * sr) / hop)
                var k = at
                while k > back && energy[k - 1] > startLevel { k -= 1 }
                at = k
                let t = (Double(at - lagS / 2) * Double(hop) + Double(win) / 2) / sr
                result.append(t)
                weights.append(peakRise * max(0.05, longE[peak] - floor))
                i = peak + minGap
                continue
            }
            i += 1
        }
        return Hits(times: result, weights: weights)
    }

    /// Nearest onset to t, if within maxDist.
    static func nearest(_ list: [Double], to t: Double, maxDist: Double) -> Double? {
        guard !list.isEmpty else { return nil }
        var lo = 0, hi = list.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if list[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        var best: Double?
        for k in [lo - 1, lo] where k >= 0 && k < list.count {
            if abs(list[k] - t) <= maxDist, best.map({ abs(list[k] - t) < abs($0 - t) }) ?? true { best = list[k] }
        }
        return best
    }
}

/// Fast-changing playback values, split out so only the playhead and meters redraw.
@MainActor
final class PlayClock: ObservableObject {
    @Published var position: Double = 0
    @Published var levels: [StemKind: Float] = [:]
}

/// Plays the stems in sync through AVAudioEngine, with per-stem gain and bar-exact looping.
@MainActor
final class StemPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    let clock = PlayClock()
    var position: Double {
        get { clock.position }
        set { clock.position = newValue }
    }
    @Published private(set) var duration: Double = 0
    /// Where the edited pieces end (seconds); pieces moved past the song make the timeline longer.
    @Published private(set) var extent: Double = 0
    /// The playable timeline: the song, or longer when pieces were moved past its end.
    var length: Double { max(duration, extent) }
    @Published private(set) var peaks: [StemKind: StemPeaks] = [:]
    /// The four stems summed: the song's real waveform for the MIX view.
    @Published private(set) var mixPeaks: StemPeaks?
    @Published private(set) var onsets: [StemKind: [Double]] = [:]
    @Published private(set) var hits: [StemKind: Onsets.Hits] = [:]
    @Published private(set) var loadedID: UUID?

    private let engine = AVAudioEngine()
    private var nodes: [StemKind: AVAudioPlayerNode] = [:]
    // Stems + click → submix → output. Nothing in between: the stems play exactly as they are
    // (a time-pitch unit here, even bypassed, cut the sound into grains on recent macOS).
    private let submix = AVAudioMixerNode()
    private let clickNode = AVAudioPlayerNode()
    private var clickTrack: AVAudioPCMBuffer?
    private var clickGrid: Grid?
    private var format: AVAudioFormat?
    @Published private(set) var clickOn = false
    @Published private(set) var rate: Double = 1
    private var startHost: UInt64 = 0
    private var urls: [StemKind: URL] = [:]
    private var files: [StemKind: AVAudioFile] = [:]
    private var sampleRate: Double = 44100
    /// The stems' sample rate (a piece slides by these samples).
    var stemRate: Double { sampleRate }
    private var gains: [StemKind: Float] = [:]

    /// Edited lanes: audible runs per stem (nil = the stem plays as it is).
    private var segs: [StemKind: [Seg]] = [:]
    private var loopRange: ClosedRange<Double>?
    private var loopOn = false

    // Where the current playback started, to turn the node's sample time into a song position.
    private var playFrom: AVAudioFramePosition = 0
    private var playLoop: (start: AVAudioFramePosition, end: AVAudioFramePosition)?
    private var timer: Timer?
    private var generation = 0

    init() {
        for kind in StemKind.allCases {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            nodes[kind] = node
        }
        engine.attach(clickNode)
        engine.attach(submix)
        engine.connect(submix, to: engine.mainMixerNode, format: nil)
        clickNode.volume = 0
    }

    func load(song: Song, dir: URL) {
        stop()
        generation += 1
        let gen = generation
        files = [:]
        urls = [:]
        peaks = [:]
        mixPeaks = nil
        onsets = [:]
        hits = [:]
        loadedID = song.id
        position = 0
        extent = 0
        segs = [:]
        var format: AVAudioFormat?
        for kind in StemKind.allCases {
            let url = dir.appendingPathComponent(kind.fileName)
            guard let file = try? AVAudioFile(forReading: url) else { continue }
            files[kind] = file
            urls[kind] = url
            format = file.processingFormat
        }
        guard let format else { duration = 0; return }
        self.format = format
        sampleRate = format.sampleRate
        duration = Double(files.values.map(\.length).max() ?? 0) / sampleRate
        if engine.isRunning { engine.stop() }
        for (kind, node) in nodes {
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: submix, format: format)
            node.volume = gains[kind] ?? 1
        }
        engine.disconnectNodeOutput(clickNode)
        engine.connect(clickNode, to: submix, format: format)
        engine.disconnectNodeOutput(submix)
        engine.connect(submix, to: engine.mainMixerNode, format: format)
        clickTrack = nil
        if let g = clickGrid { buildClickTrack(g) }
        let list = urls
        Task.detached(priority: .userInitiated) {
            var result: [StemKind: StemPeaks] = [:]
            await withTaskGroup(of: (StemKind, StemPeaks?).self) { group in
                for (kind, url) in list {
                    group.addTask { (kind, StemPeaks.compute(url: url)) }
                }
                for await (kind, p) in group { if let p { result[kind] = p } }
            }
            let done = result
            await MainActor.run { [weak self] in
                guard let self, self.generation == gen else { return }
                self.peaks = done
            }
            let mixURLs = StemKind.separated.compactMap { list[$0] }
            let mix = StemPeaks.compute(urls: mixURLs)
            await MainActor.run { [weak self] in
                guard let self, self.generation == gen else { return }
                self.mixPeaks = mix
            }
            var found: [StemKind: Onsets.Hits] = [:]
            await withTaskGroup(of: (StemKind, Onsets.Hits).self) { group in
                for (kind, url) in list {
                    group.addTask { (kind, Onsets.compute(url: url)) }
                }
                for await (kind, o) in group { found[kind] = o }
            }
            let all = found
            await MainActor.run { [weak self] in
                guard let self, self.generation == gen else { return }
                self.hits = all
                self.onsets = all.mapValues(\.times)
            }
        }
    }

    func unload() {
        stop()
        files = [:]
        urls = [:]
        peaks = [:]
        loadedID = nil
        duration = 0
        extent = 0
        position = 0
    }

    // MARK: Transport

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard !files.isEmpty else { return }
        if position >= length - 0.01 && !(loopOn && loopRange != nil) { position = 0 }
        start(at: position)
    }

    /// Gets the engine running and its clock ticking, so the next play() starts exactly `lead` (50 ms) later.
    func warmUp() {
        if !engine.isRunning { try? engine.start() }
        var tries = 0
        while (clickNode.lastRenderTime == nil || !(clickNode.lastRenderTime!.isSampleTimeValid)) && tries < 40 {
            usleep(5000); tries += 1
        }
    }

    func pause() {
        let p = currentPosition()
        stopNodes()
        position = p
    }

    func stop() {
        stopNodes()
    }

    func seek(_ t: Double) {
        let t = min(max(0, t), length)
        if isPlaying {
            start(at: t)
        } else {
            position = t
        }
    }

    func setGains(_ g: [StemKind: Float]) {
        gains = g
        for (kind, node) in nodes { node.volume = g[kind] ?? 1 }
    }

    // MARK: Metronome and warp

    /// Fine timing of the click by ear (ms, negative = earlier).
    var clickOffsetMs: Double = UserDefaults.standard.double(forKey: "clickOffsetMs") {
        didSet {
            UserDefaults.standard.set(clickOffsetMs, forKey: "clickOffsetMs")
            if let g = clickGrid { buildClickTrack(g); if isPlaying { start(at: currentPosition()) } }
        }
    }

    /// Metronome sound (right-click CLICK): "metal" rings like a struck metal bar (Logic's Klopfgeist),
    /// "tick" is the short electronic tick.
    var clickSound: String = UserDefaults.standard.string(forKey: "clickSound") ?? "metal" {
        didSet {
            UserDefaults.standard.set(clickSound, forKey: "clickSound")
            if let g = clickGrid { buildClickTrack(g); if isPlaying { start(at: currentPosition()) } }
        }
    }

    /// One click, the same on every beat. Both start at full level on their very first sample (the beat).
    nonisolated static func clickSound(_ kind: String, sampleRate sr: Double) -> [Float] {
        var rng = SystemRandomNumberGenerator()
        if kind == "tick" {
            // A tight tick: an instant noise burst for the attack plus a short, bright tone body.
            return (0..<Int(0.02 * sr)).map { i in
                let t = Double(i) / sr
                let body = cos(2 * .pi * 2500 * t) * exp(-t * 260)
                let noise = Double.random(in: -1...1, using: &rng) * exp(-t * 2600)
                return Float(body * 0.75 + noise * 0.5)
            }
        }
        // A struck metal bar on G5: its modes ring at the bar's inharmonic ratios, the high ones die first,
        // over a short knock for the attack.
        let f0 = 783.99
        let modes: [(ratio: Double, amp: Double, decay: Double)] = [
            (1.0, 1.0, 18), (2.756, 0.55, 30), (5.404, 0.32, 48), (8.933, 0.16, 70), (13.34, 0.08, 95),
        ]
        let n = Int(0.18 * sr)
        var out = [Float](repeating: 0, count: n)
        var peak: Float = 0
        for i in 0..<n {
            let t = Double(i) / sr
            var v = 0.0
            for m in modes { v += m.amp * cos(2 * .pi * f0 * m.ratio * t) * exp(-t * m.decay) }
            v += Double.random(in: -1...1, using: &rng) * 0.6 * exp(-t * 1800)   // the knock
            out[i] = Float(v)
            peak = max(peak, abs(out[i]))
        }
        if peak > 0 { for i in 0..<n { out[i] *= 0.95 / peak } }
        // The last 30 ms fade to silence, so the cut does not click.
        let tail = Int(0.03 * sr)
        for i in 0..<tail { out[n - tail + i] *= Float(tail - i) / Float(tail) }
        return out
    }

    /// Metronome level (right-click CLICK): soft, medium or loud.
    var clickVolume: Double = UserDefaults.standard.object(forKey: "clickVolume") as? Double ?? 1.0 {
        didSet {
            UserDefaults.standard.set(clickVolume, forKey: "clickVolume")
            if clickOn { clickNode.volume = Float(clickVolume) }
        }
    }

    func setClick(_ on: Bool) {
        clickOn = on
        clickNode.volume = on ? Float(clickVolume) : 0
    }

    /// The bar grid the metronome follows. Rebuilds the click track and re-syncs playback.
    func setGrid(_ g: Grid?) {
        guard g != clickGrid else { return }
        clickGrid = g
        if let g { buildClickTrack(g) } else { clickTrack = nil }
        if isPlaying { start(at: currentPosition()) }
    }

    /// The edited pieces per stem. Re-syncs playback when it changes.
    func setArrangement(_ a: [StemKind: [Seg]]) {
        guard a != segs else { return }
        segs = a
        // Pieces past the end of the song lengthen the timeline (and the click under it).
        // Only where there is audio: a piece reaching past the song's own end plays silence there.
        var end = 0.0
        if let g = clickGrid {
            let songEnd = g.tick(at: duration)
            for s in a.values {
                for sg in s {
                    let audible = min(Double(sg.len), songEnd - Double(sg.src))
                    if audible > 0 { end = max(end, g.time(g.firstBarBeat + (Double(sg.tl) + audible) / Double(ticksPerBeat))) }
                }
            }
        }
        if abs(end - extent) > 1e-6 {
            let old = length
            extent = end
            if abs(length - old) > 1e-6, let g = clickGrid { buildClickTrack(g) }
        }
        if isPlaying { start(at: currentPosition()) }
    }

    /// Timeline frames [from, to) of an edited stem, put together from its pieces (2 ms fades at the cuts).
    nonisolated static func renderTimeline(url: URL, segs: [Seg], grid g: Grid, sampleRate sr: Double,
                                           from: AVAudioFramePosition, to: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        guard to > from, let probe = try? AVAudioFile(forReading: url),
              let out = AVAudioPCMBuffer(pcmFormat: probe.processingFormat, frameCapacity: AVAudioFrameCount(to - from)),
              let d = out.floatChannelData else { return nil }
        let n = Int(to - from)
        out.frameLength = AVAudioFrameCount(n)
        let ch = Int(probe.processingFormat.channelCount)
        for c in 0..<ch { d[c].update(repeating: 0, count: n) }
        let fade = Int(0.002 * sr)
        for sg in segs {
            let tl0 = AVAudioFramePosition((g.tickTime(sg.tl) * sr).rounded())
            let tl1 = AVAudioFramePosition((g.tickTime(sg.tl + sg.len) * sr).rounded())
            let src0 = AVAudioFramePosition(((g.tickTime(sg.src) - sg.slip) * sr).rounded())
            let a = max(tl0, from), b = min(tl1, to)
            guard b > a else { continue }
            let srcA = src0 + (a - tl0)
            guard let piece = readBuffer(url: url, from: srcA, to: srcA + (b - a)) else { continue }
            if sg.hasFades { applyFades(piece, sg, grid: g, startTime: Double(a) / sr) }
            guard let p = piece.floatChannelData else { continue }
            let len = Int(b - a), off = Int(a - from)
            for c in 0..<ch {
                for i in 0..<len {
                    var v = p[c][i]
                    // Short fades only where the piece is cut, not across the whole lane.
                    let fromStart = Int(a - tl0) + i, toEnd = Int(tl1 - a) - i
                    if fromStart < fade { v *= Float(fromStart) / Float(fade) }
                    if toEnd < fade { v *= Float(max(0, toEnd)) / Float(fade) }
                    d[c][off + i] += v
                }
            }
        }
        return out
    }

    /// The piece's fade curve on a buffer that starts at timeline time `startTime` (only the fade zones are touched).
    nonisolated static func applyFades(_ buf: AVAudioPCMBuffer, _ sg: Seg, grid g: Grid, startTime: Double) {
        guard let d = buf.floatChannelData else { return }
        let sr = buf.format.sampleRate, n = Int(buf.frameLength), ch = Int(buf.format.channelCount)
        let sb = g.firstBarBeat + Double(sg.tl) / Double(ticksPerBeat)
        let eb = g.firstBarBeat + Double(sg.tl + sg.len) / Double(ticksPerBeat)
        let inEnd = sg.fadeIn > 0 ? g.time(sb + sg.fadeIn) : -Double.infinity
        let outStart = sg.fadeOut > 0 ? g.time(eb - sg.fadeOut) : Double.infinity
        for i in 0..<n {
            let t = startTime + Double(i) / sr
            guard t < inEnd || t >= outStart else { continue }
            let gain = sg.fadeGain(g.pos(at: t))
            for c in 0..<ch { d[c][i] *= gain }
        }
    }

    /// A click on every beat of the grid, the same bright tick each time, as long as the song.
    private func buildClickTrack(_ g: Grid) {
        guard let format, length > 0 else { return }
        let total = AVAudioFrameCount(length * sampleRate)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total), let data = buf.floatChannelData else { return }
        buf.frameLength = total
        let ch = Int(format.channelCount)
        for c in 0..<ch { data[c].update(repeating: 0, count: Int(total)) }
        let tick = Self.clickSound(clickSound, sampleRate: sampleRate)
        let clickLen = tick.count
        let shift = clickOffsetMs / 1000
        var b = floor(g.beat(at: 0))
        while true {
            let t = g.time(b) + shift
            if t >= length { break }
            let start = Int((t * sampleRate).rounded())
            let wave = tick
            if start + clickLen > 0 {
                for i in 0..<clickLen {
                    let j = start + i
                    guard j >= 0, j < Int(total) else { continue }
                    for c in 0..<ch { data[c][j] += wave[i] }
                }
            }
            b += 1
        }
        clickTrack = buf
    }

    private func clickSlice(from: AVAudioFramePosition, to: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        guard let src = clickTrack, to > from, let format,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(to - from)),
              let d = out.floatChannelData, let s = src.floatChannelData else { return nil }
        let n = Int(to - from)
        out.frameLength = AVAudioFrameCount(n)
        let avail = Int(src.frameLength)
        for c in 0..<Int(format.channelCount) {
            d[c].update(repeating: 0, count: n)
            let lo = max(0, Int(from)), hi = min(avail, Int(to))
            if hi > lo { (d[c] + (lo - Int(from))).update(from: s[c] + lo, count: hi - lo) }
        }
        return out
    }

    /// Loop region in seconds (bar-exact). Restarts playback if it changes what is heard.
    func setLoop(_ range: ClosedRange<Double>?, enabled: Bool) {
        let changed = range != loopRange || enabled != loopOn
        loopRange = range
        loopOn = enabled
        guard changed, isPlaying else { return }
        var p = currentPosition()
        if enabled, let r = range, !(r.contains(p)) { p = max(0, r.lowerBound) }
        start(at: p)
    }

    // MARK: Engine

    private func frame(_ t: Double) -> AVAudioFramePosition { AVAudioFramePosition((t * sampleRate).rounded()) }

    /// Testing: hears what goes to the speakers (the stems and the click after the mixer), muted.
    func debugCapture(_ block: @escaping (AVAudioPCMBuffer) -> Void) {
        engine.mainMixerNode.outputVolume = 0
        submix.installTap(onBus: 0, bufferSize: 4096, format: nil) { buf, _ in block(buf) }
    }

    /// Testing: each stem's player output on its own.
    func debugCaptureStems(_ block: @escaping (StemKind, AVAudioPCMBuffer) -> Void) {
        engine.mainMixerNode.outputVolume = 0
        for (k, n) in nodes { n.installTap(onBus: 0, bufferSize: 4096, format: nil) { buf, _ in block(k, buf) } }
    }

    /// How often playback was (re)started, for finding stray restarts (STEMEKI_DEBUG_LOG=<file> logs each one).
    private(set) var starts = 0
    private static let debugLog = ProcessInfo.processInfo.environment["STEMEKI_DEBUG_LOG"]

    private func start(at t: Double, _ caller: String = #function, _ line: Int = #line) {
        starts += 1
        if let path = Self.debugLog, let h = FileHandle(forWritingAtPath: path) ?? {
            FileManager.default.createFile(atPath: path, contents: nil); return FileHandle(forWritingAtPath: path) }() {
            h.seekToEndOfFile()
            h.write(String(format: "%.3f start #%d at %.3f from %@:%d\n", Date().timeIntervalSince1970, starts, t, caller, line).data(using: .utf8)!)
            try? h.close()
        }
        stopNodes()
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            return
        }
        let total = AVAudioFramePosition(length * sampleRate)
        var from = min(max(0, frame(t)), total)
        playLoop = nil

        if loopOn, let r = loopRange {
            let ls = frame(r.lowerBound), le = min(frame(r.upperBound), total)
            if le - ls > 64 {
                if from < max(ls, 0) || from >= le { from = max(ls, 0) }
                playLoop = (ls, le)
                for (kind, node) in nodes {
                    guard let url = urls[kind] else { continue }
                    let edited = segs[kind]
                    func read(_ a: AVAudioFramePosition, _ b: AVAudioFramePosition) -> AVAudioPCMBuffer? {
                        if let edited, let g = clickGrid {
                            return Self.renderTimeline(url: url, segs: edited, grid: g, sampleRate: sampleRate, from: a, to: b)
                        }
                        return Self.readBuffer(url: url, from: a, to: b)
                    }
                    guard let loopBuf = read(ls, le) else { continue }
                    // From the playhead to the loop end once, then the whole loop forever.
                    if from > ls, let head = read(from, le) {
                        node.scheduleBuffer(head, at: nil, options: [])
                    }
                    node.scheduleBuffer(loopBuf, at: nil, options: .loops)
                }
                if let loopClick = clickSlice(from: ls, to: le) {
                    if from > ls, let head = clickSlice(from: from, to: le) { clickNode.scheduleBuffer(head, at: nil, options: []) }
                    clickNode.scheduleBuffer(loopClick, at: nil, options: .loops)
                }
            }
        }
        if playLoop == nil {
            guard total - from > 0 else { return }
            for (kind, node) in nodes {
                guard let file = files[kind] else { continue }
                guard let edited = segs[kind], let g = clickGrid else {
                    if file.length > from {
                        node.scheduleSegment(file, startingFrame: from,
                                             frameCount: AVAudioFrameCount(file.length - from), at: nil)
                    }
                    continue
                }
                // Each piece at its own place on the timeline; gaps stay silent. A piece with fades plays its
                // fade zones from buffers with the curve on them, the rest straight from the file.
                let fromT = Double(from) / sampleRate
                for sg in edited {
                    let tl0 = g.tickTime(sg.tl), tl1 = g.tickTime(sg.tl + sg.len)
                    guard tl1 > fromT else { continue }
                    let srcT = g.tickTime(sg.src) - sg.slip
                    let inEnd = sg.fadeIn > 0 ? min(tl1, g.time(g.firstBarBeat + Double(sg.tl) / Double(ticksPerBeat) + sg.fadeIn)) : tl0
                    let outStart = sg.fadeOut > 0
                        ? max(inEnd, g.time(g.firstBarBeat + Double(sg.tl + sg.len) / Double(ticksPerBeat) - sg.fadeOut)) : tl1
                    for (a, b, faded) in [(tl0, inEnd, true), (inEnd, outStart, false), (outStart, tl1, true)] where b > a && b > fromT {
                        var at = max(a, fromT)
                        var sf = frame(srcT + (at - tl0))
                        let ef = min(frame(srcT + (b - tl0)), file.length)
                        if sf < 0 { at += Double(-sf) / sampleRate; sf = 0 }
                        guard ef > sf else { continue }
                        let when = AVAudioTime(sampleTime: AVAudioFramePosition(((at - fromT) * sampleRate).rounded()), atRate: sampleRate)
                        if faded, let url = urls[kind], let buf = Self.readBuffer(url: url, from: sf, to: ef) {
                            Self.applyFades(buf, sg, grid: g, startTime: at)
                            node.scheduleBuffer(buf, at: when, options: [])
                        } else {
                            node.scheduleSegment(file, startingFrame: sf, frameCount: AVAudioFrameCount(ef - sf), at: when)
                        }
                    }
                }
            }
            if let c = clickSlice(from: from, to: total) { clickNode.scheduleBuffer(c, at: nil, options: []) }
        }
        playFrom = from
        // Every stem and the click start on the same sample of the engine's timeline. Started by host time,
        // the players came out 10–20 ms apart on recent macOS: the kick flammed against the rest and the
        // music seemed to jump from beat to beat.
        let lead = 0.05
        var ref = clickNode.lastRenderTime
        var tries = 0
        while (ref == nil || !(ref!.isSampleTimeValid)) && tries < 40 {
            usleep(5000); tries += 1; ref = clickNode.lastRenderTime
        }
        let when: AVAudioTime
        if let ref, ref.isSampleTimeValid {
            when = AVAudioTime(sampleTime: ref.sampleTime + AVAudioFramePosition(lead * ref.sampleRate), atRate: ref.sampleRate)
            startHost = (ref.isHostTimeValid ? ref.hostTime : mach_absolute_time()) + AVAudioTime.hostTime(forSeconds: lead)
        } else {
            startHost = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: lead)
            when = AVAudioTime(hostTime: startHost)
        }
        for node in nodes.values { node.play(at: when) }
        clickNode.play(at: when)
        isPlaying = true
        position = Double(from) / sampleRate
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 40, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopNodes() {
        timer?.invalidate()
        timer = nil
        for node in nodes.values { node.stop() }
        clickNode.stop()
        isPlaying = false
        clock.levels = [:]
    }

    /// Song position from the output clock (the player's own sample time is unreliable behind a time-stretch).
    private func currentPosition() -> Double {
        guard isPlaying, let rt = engine.outputNode.lastRenderTime, rt.isHostTimeValid else { return position }
        let elapsed = max(0, AVAudioTime.seconds(forHostTime: rt.hostTime) - AVAudioTime.seconds(forHostTime: startHost))
        var f = playFrom + AVAudioFramePosition(elapsed * rate * sampleRate)
        if let l = playLoop, f >= l.end {
            let len = l.end - l.start
            f = l.start + (f - l.end) % len
        }
        return Double(f) / sampleRate
    }

    private func tick() {
        let p = currentPosition()
        position = p
        if playLoop == nil && p >= length - 0.005 {
            stopNodes()
            position = length
            return
        }
        var lv: [StemKind: Float] = [:]
        for (kind, pk) in peaks { lv[kind] = pk.rmsAt(p) * (gains[kind] ?? 1) }
        clock.levels = lv
    }

    /// Reads frames [from, to) of a stem; frames before 0 or past the end come back as silence.
    nonisolated static func readBuffer(url: URL, from: AVAudioFramePosition, to: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        guard to > from, let file = try? AVAudioFile(forReading: url) else { return nil }
        let count = AVAudioFrameCount(to - from)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count),
              let data = buf.floatChannelData else { return nil }
        buf.frameLength = count
        let ch = Int(file.processingFormat.channelCount)
        for c in 0..<ch { data[c].update(repeating: 0, count: Int(count)) }
        let readStart = max(0, from)
        let readEnd = min(to, file.length)
        guard readEnd > readStart else { return buf }
        let n = AVAudioFrameCount(readEnd - readStart)
        guard let tmp = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n) else { return nil }
        file.framePosition = readStart
        do { try file.read(into: tmp, frameCount: n) } catch { return nil }
        let offset = Int(readStart - from)
        if let src = tmp.floatChannelData {
            for c in 0..<ch {
                (data[c] + offset).update(from: src[c], count: Int(tmp.frameLength))
            }
        }
        return buf
    }
}
