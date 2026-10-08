import Foundation
import AVFoundation
import Accelerate

/// Cuts bar-exact loops out of the stems and writes them in the original file's format.
struct ExportJob: Sendable {
    struct Output: Sendable {
        var tag: String               // VOCALS, DRUMS, MIX…
        var stems: [StemKind: Float]  // stem → gain
        /// Edited lanes: each part is some stems with that lane's pieces. nil = everything unedited.
        var parts: [Part]? = nil
        /// File name without extension (if nil: base_tag_range).
        var name: String? = nil
    }

    /// ACID / smpl data written into WAV files so loop-aware software sees tempo, length and loop points.
    struct Acid: Sendable {
        var tempo: Double
        var beats: Int
        var rootNote: Int?      // MIDI note of the key's root
        var loop: Bool          // also write loop points (smpl)
    }

    struct Part: Sendable {
        var stems: [StemKind: Float]
        var segs: [Seg]?
    }

    var stemsDir: URL
    var outDir: URL
    var baseName: String          // "SONG_126bpm_Am"
    var rangeName: String         // "bar17-20" or "full_bar1-64"
    var start: Double
    var end: Double
    var outputs: [Output]
    var fadeMs: Double?
    var grid: Grid                // warp markers: beat ↔ time in the stems
    var beatStart: Double         // first beat of the loop
    var beats: Double             // loop length in beats
    var targetBpm: Double         // tempo the loop comes out at
    /// false: keep the original tempo and timing (FULL stems).
    var stretch: Bool = true
    var acid: Acid? = nil

    var sampleRate: Double
    var bits: Int
    var isFloat: Bool
    var channels: Int
    var ext: String               // wav, aif, aiff, flac
}

enum ExportError: LocalizedError {
    case read, convert, write(String)
    var errorDescription: String? {
        switch self {
        case .read: return "Could not read the stems"
        case .convert: return "Sample rate conversion failed"
        case .write(let s): return "Write error: \(s)"
        }
    }
}

enum Exporter {
    /// Container for the loops: same as the source when it is lossless, WAV otherwise.
    static func outputExt(forSource ext: String) -> String {
        switch ext {
        case "wav", "aif", "aiff", "flac": return ext
        default: return "wav"
        }
    }

    /// Stretch needed? Not when every grid segment in the loop is already at the target tempo.
    static func needsWarp(_ job: ExportJob) -> Bool {
        let p = 60 / job.targetBpm
        var b = job.beatStart
        while b < job.beatStart + job.beats {
            let len = job.grid.time(b + 1) - job.grid.time(b)
            if abs(len - p) > p * 2e-5 { return true }
            b += 1
        }
        return false
    }

    static func run(_ job: ExportJob) throws -> [URL] {
        try FileManager.default.createDirectory(at: job.outDir, withIntermediateDirectories: true)

        let needed = Set(job.outputs.flatMap { $0.stems.keys })
        guard let probeURL = needed.first.map({ job.stemsDir.appendingPathComponent($0.fileName) }),
              let probe = try? AVAudioFile(forReading: probeURL) else { throw ExportError.read }
        let stemRate = probe.processingFormat.sampleRate
        let resample = abs(stemRate - job.sampleRate) > 0.5
        let warp = job.stretch && needsWarp(job)

        // Source region: the loop plus pre-roll for the stretcher / resampler.
        let preBeats = warp ? 1.0 : 0.0
        let srcStart = job.grid.time(job.beatStart - preBeats)
        let srcEnd = job.grid.time(job.beatStart + job.beats + (warp ? 1 : 0))
        let margin: AVAudioFramePosition = resample ? 8192 : 0
        let from = AVAudioFramePosition((srcStart * stemRate).rounded()) - margin
        let to = AVAudioFramePosition((srcEnd * stemRate).rounded()) + margin

        var stemBuffers: [StemKind: AVAudioPCMBuffer] = [:]
        for kind in needed {
            guard let b = StemPlayer.readBuffer(url: job.stemsDir.appendingPathComponent(kind.fileName), from: from, to: to)
            else { throw ExportError.read }
            stemBuffers[kind] = b
        }

        // Exact length in the output's own clock.
        let loopSeconds = warp ? job.beats * 60 / job.targetBpm
                               : job.grid.time(job.beatStart + job.beats) - job.grid.time(job.beatStart)
        let outLength = Int((loopSeconds * job.sampleRate).rounded())

        var written: [URL] = []
        for output in job.outputs {
            var buf: AVAudioPCMBuffer
            // Seconds of pre-roll left in front of the loop start.
            var lead = Double(margin) / stemRate
            if let parts = output.parts, parts.contains(where: { $0.segs != nil }) {
                // Edited audio: put the pieces together.
                buf = try renderEdited(parts, job: job, stemRate: stemRate, warp: warp, preBeats: preBeats,
                                       from: from, to: to, format: probe.processingFormat)
                if warp { lead = preBeats * 60 / job.targetBpm }
            } else {
                guard let mixed = mix(output.stems, stemBuffers) else { throw ExportError.read }
                buf = mixed
                if warp {
                    buf = try warpRender(mixed, job: job, inStart: Double(from) / stemRate,
                                         preBeats: preBeats)
                    lead = preBeats * 60 / job.targetBpm
                }
            }
            if resample { buf = try convert(buf, to: job.sampleRate) }
            let offset = Int((lead * job.sampleRate).rounded())
            let final = try slice(buf, offset: offset, length: outLength, channels: job.channels)
            if let ms = job.fadeMs, ms > 0 { fade(final, frames: Int(ms / 1000 * job.sampleRate)) }

            let name = (output.name ?? "\(job.baseName)_\(output.tag)_\(job.rangeName)") + ".\(job.ext)"
            let url = job.outDir.appendingPathComponent(name)
            try write(final, to: url, job: job)
            if job.ext == "wav", let acid = job.acid { try? addAcidChunks(url, acid, frames: Int(final.frameLength), sampleRate: job.sampleRate) }
            if job.ext == "wav" { try? addInfoChunk(url, title: url.deletingPathExtension().lastPathComponent) }
            written.append(url)
        }
        return written
    }

    /// Edited lanes: without a stretch the pieces are laid on the timeline; with one, WSOLA reads
    /// each output moment from wherever its piece comes from (silence where a piece was deleted).
    private static func renderEdited(_ parts: [ExportJob.Part], job: ExportJob, stemRate: Double, warp: Bool, preBeats: Double,
                                     from: AVAudioFramePosition, to: AVAudioFramePosition,
                                     format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let g = job.grid
        var total: AVAudioPCMBuffer?
        func add(_ b: AVAudioPCMBuffer, _ gain: Float) {
            if total == nil {
                total = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength)
                total?.frameLength = b.frameLength
                if let d = total?.floatChannelData {
                    for c in 0..<Int(b.format.channelCount) { d[c].update(repeating: 0, count: Int(b.frameLength)) }
                }
            }
            guard let t = total, let d = t.floatChannelData, let s = b.floatChannelData else { return }
            let n = Int(min(t.frameLength, b.frameLength))
            for c in 0..<Int(b.format.channelCount) { for i in 0..<n { d[c][i] += s[c][i] * gain } }
        }
        for part in parts {
            if !warp {
                for (kind, gain) in part.stems {
                    let url = job.stemsDir.appendingPathComponent(kind.fileName)
                    let b = part.segs.map { StemPlayer.renderTimeline(url: url, segs: $0, grid: g, sampleRate: stemRate, from: from, to: to) }
                        ?? StemPlayer.readBuffer(url: url, from: from, to: to)
                    guard let b else { throw ExportError.read }
                    add(b, gain)
                }
                continue
            }
            // Which stretch of the song this part reads from.
            let beat0 = job.beatStart - preBeats
            let outBeats = job.beats + preBeats * 2
            var lo = Double.infinity, hi = -Double.infinity
            var b = beat0
            while b <= beat0 + outBeats {
                if let sb = g.sourceBeat(b, part.segs) { let t = g.time(sb); lo = min(lo, t); hi = max(hi, t) }
                b += 0.25
            }
            let outFrames = Int((outBeats * 60 / job.targetBpm * stemRate).rounded())
            guard lo.isFinite else {
                // All silent here.
                guard let z = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(outFrames)) else { throw ExportError.convert }
                z.frameLength = AVAudioFrameCount(outFrames)
                if let d = z.floatChannelData { for c in 0..<Int(format.channelCount) { d[c].update(repeating: 0, count: outFrames) } }
                add(z, 1)
                continue
            }
            let inFrom = AVAudioFramePosition(((lo - 0.5) * stemRate).rounded())
            let inTo = AVAudioFramePosition(((hi + 0.5) * stemRate).rounded())
            var stemBufs: [StemKind: AVAudioPCMBuffer] = [:]
            for kind in part.stems.keys {
                guard let rb = StemPlayer.readBuffer(url: job.stemsDir.appendingPathComponent(kind.fileName), from: inFrom, to: inTo)
                else { throw ExportError.read }
                stemBufs[kind] = rb
            }
            guard let input = mix(part.stems, stemBufs) else { throw ExportError.read }
            let inStart = Double(inFrom) / stemRate
            let segs = part.segs
            let stretched = try wsola(input, frames: outFrames) { o in
                let ob = beat0 + Double(o) / stemRate * job.targetBpm / 60
                guard let sb = g.sourceBeat(ob, segs) else { return nil }
                return (g.time(sb) - inStart) * stemRate
            }
            // The pieces' fades, on the output's beats.
            if let segs, segs.contains(where: \.hasFades), let d = stretched.floatChannelData {
                let sr = stretched.format.sampleRate
                for o in 0..<Int(stretched.frameLength) {
                    let gain = g.fadeGain(atBeat: beat0 + Double(o) / sr * job.targetBpm / 60, segs)
                    if gain < 1 { for c in 0..<Int(stretched.format.channelCount) { d[c][o] *= gain } }
                }
            }
            add(stretched, 1)
        }
        guard let total else { throw ExportError.read }
        return total
    }

    /// Pitch-preserving stretch onto a constant tempo, following the warp markers. Output frame 0
    /// is `preBeats` before the loop start.
    private static func warpRender(_ input: AVAudioPCMBuffer, job: ExportJob, inStart: Double,
                                   preBeats: Double) throws -> AVAudioPCMBuffer {
        let sr = input.format.sampleRate
        let beat0 = job.beatStart - preBeats
        let outBeats = job.beats + preBeats * 2
        let outFrames = Int((outBeats * 60 / job.targetBpm * sr).rounded())
        return try wsola(input, frames: outFrames) { o in
            let b = beat0 + Double(o) / sr * job.targetBpm / 60
            return (job.grid.time(b) - inStart) * sr
        }
    }

    /// WSOLA time-stretch: overlapping Hann grains, each taken from where `source(o)` says (within a
    /// few ms, chosen for the smoothest join). Timing follows the map exactly and never drifts; pitch
    /// is untouched.
    private static func wsola(_ input: AVAudioPCMBuffer, frames: Int, source: (Int) -> Double?) throws -> AVAudioPCMBuffer {
        let format = input.format
        let ch = Int(format.channelCount)
        // 93 ms grains: long enough that a bass cycle or a sustained chord is never cut apart, and the
        // similarity search keeps drum hits whole (measured: 1% of 25 ms blocks off, against 10% with 23 ms).
        let n = Int(ProcessInfo.processInfo.environment["STEMEKI_WSOLA_N"] ?? "") ?? 4096
        let hop = n / 2, tol = n / 8
        let inLen = Int(input.frameLength)
        guard let src = input.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let dst = out.floatChannelData else { throw ExportError.convert }
        out.frameLength = AVAudioFrameCount(frames)
        // Mono guide signal for the similarity search, zero-padded so grains can run off the edges.
        let pad = n + tol + 8
        var mono = [Float](repeating: 0, count: inLen + 2 * pad)
        for i in 0..<inLen {
            var v: Float = 0
            for c in 0..<ch { v += src[c][i] }
            mono[pad + i] = v
        }
        let window = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
        var acc = [[Float]](repeating: [Float](repeating: 0, count: frames + n), count: ch)
        var wsum = [Float](repeating: 0, count: frames + n)

        func sample(_ c: Int, _ i: Int) -> Float { i >= 0 && i < inLen ? src[c][i] : 0 }

        var prev = Int.min
        var m = 0
        while m * hop - n / 2 < frames {
            let centre = m * hop
            guard let srcPos = source(centre) else {
                // Silence here (a deleted piece): keep the window weight so it fades to zero.
                let o0 = centre - n / 2
                for k in 0..<n where o0 + k >= 0 && o0 + k < frames + n { wsum[o0 + k] += window[k] }
                prev = Int.min
                m += 1
                continue
            }
            let want = Int(srcPos.rounded()) - n / 2
            var chosen = want
            if prev != Int.min {
                // Natural continuation of the previous grain, to match against.
                let nat = prev + hop
                func similarity(_ cand: Int) -> Float {
                    var s: Float = 0
                    mono.withUnsafeBufferPointer { mp in
                        let a = mp.baseAddress! + pad + cand, b = mp.baseAddress! + pad + nat
                        vDSP_dotpr(a, 1, b, 1, &s, vDSP_Length(n - hop))
                    }
                    return s
                }
                var best = want, bestS = -Float.infinity
                // Coarse then fine search.
                var d = -tol
                while d <= tol {
                    let sc = similarity(want + d)
                    if sc > bestS { bestS = sc; best = want + d }
                    d += 4
                }
                let coarse = best
                for d2 in -3...3 where abs(coarse + d2 - want) <= tol {
                    let sc = similarity(coarse + d2)
                    if sc > bestS { bestS = sc; best = coarse + d2 }
                }
                chosen = best
            }
            let o0 = centre - n / 2
            for k in 0..<n {
                let o = o0 + k
                guard o >= 0, o < frames + n else { continue }
                let w = window[k]
                for c in 0..<ch { acc[c][o] += sample(c, chosen + k) * w }
                wsum[o] += w
            }
            prev = chosen
            m += 1
        }
        for c in 0..<ch {
            let d = dst[c]
            for i in 0..<frames { d[i] = wsum[i] > 1e-3 ? acc[c][i] / wsum[i] : 0 }
        }
        return out
    }

    private static func mix(_ stems: [StemKind: Float], _ buffers: [StemKind: AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let first = buffers[stems.keys.first ?? .vocals],
              let out = AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: first.frameLength),
              let dst = out.floatChannelData else { return nil }
        out.frameLength = first.frameLength
        let n = Int(first.frameLength)
        let ch = Int(first.format.channelCount)
        for c in 0..<ch { dst[c].update(repeating: 0, count: n) }
        for (kind, gain) in stems {
            guard let b = buffers[kind], let src = b.floatChannelData else { continue }
            for c in 0..<ch {
                let d = dst[c], s = src[c]
                for i in 0..<n { d[i] += s[i] * gain }
            }
        }
        return out
    }

    private static func convert(_ input: AVAudioPCMBuffer, to rate: Double) throws -> AVAudioPCMBuffer {
        guard let outFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: input.format.channelCount),
              let conv = AVAudioConverter(from: input.format, to: outFormat) else { throw ExportError.convert }
        conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        conv.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        conv.primeMethod = .normal
        let cap = AVAudioFrameCount(Double(input.frameLength) * rate / input.format.sampleRate) + 4096
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { throw ExportError.convert }
        var given = false
        var err: NSError?
        let status = conv.convert(to: out, error: &err) { _, st in
            if given { st.pointee = .endOfStream; return nil }
            given = true
            st.pointee = .haveData
            return input
        }
        if status == .error { throw ExportError.convert }
        return out
    }

    /// Exactly `length` frames from `offset`, zero-padded, down-mixed to mono if the source was mono.
    private static func slice(_ buf: AVAudioPCMBuffer, offset: Int, length: Int, channels: Int) throws -> AVAudioPCMBuffer {
        let ch = max(1, min(channels, Int(buf.format.channelCount)))
        guard length > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: buf.format.sampleRate, channels: AVAudioChannelCount(ch)),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length)),
              let dst = out.floatChannelData, let src = buf.floatChannelData else { throw ExportError.convert }
        out.frameLength = AVAudioFrameCount(length)
        let avail = Int(buf.frameLength)
        let srcCh = Int(buf.format.channelCount)
        for c in 0..<ch {
            let d = dst[c]
            for i in 0..<length {
                let j = offset + i
                guard j >= 0, j < avail else { d[i] = 0; continue }
                if ch == 1 && srcCh > 1 {
                    var s: Float = 0
                    for k in 0..<srcCh { s += src[k][j] }
                    d[i] = s / Float(srcCh)
                } else {
                    d[i] = src[c][j]
                }
            }
        }
        return out
    }

    private static func fade(_ buf: AVAudioPCMBuffer, frames: Int) {
        let n = Int(buf.frameLength)
        let f = min(frames, n / 2)
        guard f > 1, let data = buf.floatChannelData else { return }
        for c in 0..<Int(buf.format.channelCount) {
            let d = data[c]
            for i in 0..<f {
                let g = Float(i) / Float(f)
                d[i] *= g
                d[n - 1 - i] *= g
            }
        }
    }

    private static func write(_ buf: AVAudioPCMBuffer, to url: URL, job: ExportJob) throws {
        var settings: [String: Any] = [
            AVSampleRateKey: job.sampleRate,
            AVNumberOfChannelsKey: Int(buf.format.channelCount),
        ]
        if job.ext == "flac" {
            settings[AVFormatIDKey] = kAudioFormatFLAC
            settings[AVEncoderBitDepthHintKey] = min(job.bits, 24)
        } else {
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = job.bits
            settings[AVLinearPCMIsFloatKey] = job.isFloat
            settings[AVLinearPCMIsBigEndianKey] = job.ext != "wav"
            settings[AVLinearPCMIsNonInterleaved] = false
        }
        try? FileManager.default.removeItem(at: url)
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buf)
        } catch {
            throw ExportError.write(error.localizedDescription)
        }
    }

    /// "Made with STEMEKI": a RIFF LIST/INFO chunk with the software, a comment and the title,
    /// which Finder and most DAWs show in the file's info.
    static func addInfoChunk(_ url: URL, title: String) throws {
        var data = try Data(contentsOf: url)
        guard data.count > 12, data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else { return }
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func field(_ id: String, _ text: String) -> Data {
            var t = Data(text.utf8); t.append(0)
            if t.count % 2 == 1 { t.append(0) }
            return Data(id.utf8) + u32(UInt32(t.count)) + t
        }
        var info = Data("INFO".utf8)
        info += field("ISFT", "STEMEKI · EKIDIO SOUND")
        info += field("ICMT", "Made with STEMEKI · stems · loops · remix")
        info += field("INAM", title)
        data += Data("LIST".utf8) + u32(UInt32(info.count)) + info
        data.replaceSubrange(4..<8, with: u32(UInt32(data.count - 8)))
        try data.write(to: url, options: .atomic)
    }

    /// Appends the ACID chunk (tempo, beats, root, loop/one-shot) and, for loops, a smpl chunk
    /// with forward loop points over the whole file. The RIFF size is updated.
    static func addAcidChunks(_ url: URL, _ a: ExportJob.Acid, frames: Int, sampleRate: Double) throws {
        var data = try Data(contentsOf: url)
        guard data.count > 12, data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else { return }
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func u16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func f32(_ v: Float) -> Data { withUnsafeBytes(of: v.bitPattern.littleEndian) { Data($0) } }

        var flags: UInt32 = 0x04                       // stretch on
        if a.rootNote != nil { flags |= 0x02 }         // root note set
        if !a.loop { flags |= 0x01 }                   // one-shot (not a loop)
        var acid = Data()
        acid += u32(flags)
        acid += u16(UInt16(a.rootNote ?? 60))
        acid += u16(0x8000)
        acid += f32(0)
        acid += u32(UInt32(max(0, a.beats)))
        acid += u16(4)                                 // meter denominator
        acid += u16(4)                                 // meter numerator
        acid += f32(Float(a.tempo))
        data += Data("acid".utf8) + u32(UInt32(acid.count)) + acid

        if a.loop {
            var smpl = Data()
            smpl += u32(0) + u32(0)                                    // manufacturer, product
            smpl += u32(UInt32((1_000_000_000 / sampleRate).rounded())) // sample period (ns)
            smpl += u32(UInt32(a.rootNote ?? 60)) + u32(0)             // unity note, pitch fraction
            smpl += u32(0) + u32(0)                                    // SMPTE format, offset
            smpl += u32(1) + u32(0)                                    // one loop, no sampler data
            smpl += u32(0) + u32(0)                                    // cue id, forward loop
            smpl += u32(0) + u32(UInt32(max(0, frames - 1)))           // start, end (inclusive)
            smpl += u32(0) + u32(0)                                    // fraction, play forever
            data += Data("smpl".utf8) + u32(UInt32(smpl.count)) + smpl
        }
        data.replaceSubrange(4..<8, with: u32(UInt32(data.count - 8)))
        try data.write(to: url, options: .atomic)
    }

    static func safeName(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let folded = s.folding(options: [.diacriticInsensitive], locale: .current)
        var out = ""
        for u in folded.unicodeScalars {
            out += allowed.contains(u) ? String(u) : "_"
        }
        while out.contains("__") { out = out.replacingOccurrences(of: "__", with: "_") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return String(out.prefix(60))
    }
}
