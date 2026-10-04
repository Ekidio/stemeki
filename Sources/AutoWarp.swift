import Foundation

/// Follows the hits beat by beat from "the 1" and pins every bar to its real downbeat,
/// so the grid stays on the music even when the tempo drifts.
enum AutoWarp {
    /// How much each stem counts when looking for the beat.
    static let stemWeight: [StemKind: Float] = [.drums: 1.0, .bass: 0.45, .other: 0.35, .vocals: 0.1]

    /// `rephase`: first move the 1 onto the phase the hits agree on (for a detected 1, not a hand-set one).
    static func compute(hits: [StemKind: Onsets.Hits], grid: Grid, rephase: Bool = false) -> [BeatPoint] {
        // All hits in one weighted, time-sorted list.
        var all: [(t: Double, w: Float)] = []
        for (kind, h) in hits {
            let sw = stemWeight[kind] ?? 0.2
            for (t, w) in zip(h.times, h.weights) { all.append((t, w * sw)) }
        }
        all.sort { $0.t < $1.t }
        guard all.count > 16 else { return [BeatPoint(beat: 0, time: grid.anchor)] }
        let times = all.map(\.t)
        let strongest = all.map(\.w).max() ?? 1
        let minWeight = strongest * 0.06

        // The drums are the most reliable beat: look there first.
        let drums = hits[.drums] ?? Onsets.Hits()
        let drumStrongest = drums.weights.max() ?? 0
        func bestDrum(near t: Double, window: Double) -> (t: Double, w: Float)? {
            let ts = drums.times
            var lo = 0, hi = ts.count
            while lo < hi { let m = (lo + hi) / 2; if ts[m] < t - window { lo = m + 1 } else { hi = m } }
            var pick: (t: Double, w: Float, score: Float)?
            var i = lo
            while i < ts.count && ts[i] <= t + window {
                let w = drums.weights[i]
                let d = Float(abs(ts[i] - t) / window)
                let score = w * (1 - 0.6 * d)
                if w >= drumStrongest * 0.08, score > (pick?.score ?? 0) { pick = (ts[i], w, score) }
                i += 1
            }
            return pick.map { ($0.t, $0.w) }
        }

        func best(near t: Double, window: Double) -> (t: Double, w: Float)? {
            if let d = bestDrum(near: t, window: window) { return d }
            return bestAny(near: t, window: window)
        }

        func bestAny(near t: Double, window: Double) -> (t: Double, w: Float)? {
            var lo = 0, hi = times.count
            while lo < hi { let m = (lo + hi) / 2; if times[m] < t - window { lo = m + 1 } else { hi = m } }
            var pick: (t: Double, w: Float, score: Float)?
            var i = lo
            while i < times.count && times[i] <= t + window {
                let d = Float(abs(times[i] - t) / window)
                let score = all[i].w * (1 - 0.6 * d)
                if all[i].w >= minWeight, score > (pick?.score ?? 0) { pick = (times[i], all[i].w, score) }
                i += 1
            }
            return pick.map { ($0.t, $0.w) }
        }

        var anchor = grid.anchor
        let p0 = 60 / grid.meanBPM

        // A steady song (a click track, a drum machine): one straight line through all the drum hits holds
        // over the whole song, and every beat is pinned to its own hit. Tracking beat by beat is for songs
        // whose tempo really moves; on a steady one it can lose a beat in a break and drift after it.
        let steady = steadyPins(drums: drums, grid: grid, p0: p0, duration: grid.duration)

        // Score of a candidate downbeat: how much hit weight sits on its next 32 beats (both ways).
        func phaseScore(_ c: Double) -> Float {
            var sc: Float = 0
            // Score from the candidate onwards: the drums after it decide (an intro can be out of phase).
            for k in 0...16 {
                if let h = best(near: c + Double(k) * p0, window: p0 * 0.05) { sc += h.w }
            }
            return sc
        }
        if rephase {
            // Candidates: the hits within half a beat of the detected 1.
            var bestC = anchor, bestS = phaseScore(anchor)
            var lo = 0, hi = times.count
            // Candidates within a whole beat either way, so the off-beat and the on-beat are both tried.
            while lo < hi { let m = (lo + hi) / 2; if times[m] < anchor - p0 { lo = m + 1 } else { hi = m } }
            var i = lo
            while i < times.count && times[i] <= anchor + p0 {
                let sc = phaseScore(times[i])
                if sc > bestS { bestS = sc; bestC = times[i] }
                i += 1
            }
            anchor = bestDrum(near: bestC, window: p0 * 0.06)?.t ?? bestC
        } else if let h = best(near: anchor, window: p0 * 0.05) {
            anchor = h.t
        }
        let duration = grid.duration

        /// Walks beat by beat in one direction; returns (beat, time) for beats that had a clear hit.
        func track(_ dir: Double) -> [(Double, Double)] {
            var found: [(Double, Double)] = [(0, anchor)]
            _ = 0
            var period = p0
            var k = 0.0
            var misses = 0
            while true {
                k += dir
                // Predict from the recent hits (a local straight line).
                let recent = found.suffix(12)
                var pred = anchor + k * period
                if let last = recent.last {
                    pred = last.1 + (k - last.0) * period
                }
                if pred < -period || pred > duration + period { break }
                if let h = best(near: pred, window: period * 0.11) {
                    found.append((k, h.t))
                    misses = 0
                    // Local tempo from the last hits, kept within ±4% of the song tempo.
                    let pts = Array(found.suffix(16))
                    if pts.count >= 4 {
                        let n = Double(pts.count)
                        let mb = pts.map(\.0).reduce(0, +) / n, mt = pts.map(\.1).reduce(0, +) / n
                        var num = 0.0, den = 0.0
                        for (b, t) in pts { num += (b - mb) * (t - mt); den += (b - mb) * (b - mb) }
                        if den > 0 { period = min(p0 * 1.04, max(p0 * 0.96, abs(num / den))) }
                    }
                } else {
                    misses += 1
                    // Long gap (breakdown): fall back towards the song tempo.
                    if misses > 8 { period = period * 0.9 + p0 * 0.1 }
                }
            }
            return found
        }

        var beats: [(Double, Double)]
        if var steady {
            // Beats still without a pin: their hit near where the section lines put them.
            let fill = Grid(points: steady.map { BeatPoint(beat: $0.0, time: $0.1) }, bpm: grid.bpm, duration: grid.duration)
            var have = Set(steady.map(\.0))
            if let lo = steady.first?.0, let hi = steady.last?.0 {
                var b = lo
                while b <= hi {
                    if !have.contains(b), let h = bestDrum(near: fill.time(b), window: p0 * 0.08) {
                        steady.append((b, h.t)); have.insert(b)
                    }
                    b += 1
                }
            }
            // Every pin comes from a hit on a fitted line: no smoothing, the grid sits on the hits.
            return steady.sorted { $0.0 < $1.0 }.map { BeatPoint(beat: $0.0, time: $0.1) }
        } else {
            beats = track(1) + track(-1).dropFirst()
            beats.sort { $0.0 < $1.0 }
        }

        // One marker per beat that had its own hit, so the grid (and the click) sit on every hit.
        var pins = beats
        // Drop markers that disagree with their neighbours (fills, flams, swing).
        var changed = true
        var rounds = 0
        while changed && rounds < 4 {
            changed = false
            rounds += 1
            var keep: [(Double, Double)] = []
            for i in pins.indices {
                if pins[i].0 == 0 || i == 0 || i == pins.count - 1 { keep.append(pins[i]); continue }
                let a = pins[i - 1], c = pins[i + 1]
                let expect = a.1 + (pins[i].0 - a.0) / (c.0 - a.0) * (c.1 - a.1)
                if abs(pins[i].1 - expect) > p0 * 0.025 { changed = true } else { keep.append(pins[i]) }
            }
            pins = keep
        }
        return pins.map { BeatPoint(beat: $0.0, time: $0.1) }
    }

    /// Section by section: the stretches where the drums play (split at gaps of a few seconds) each get their own
    /// straight beat line (the window narrowing step by step), so a song stitched from parts at slightly different
    /// tempos stays on the grid in every part. The beats are counted across the gaps from the section tempos,
    /// numbered from the grid's 1, and every beat is pinned to its own hit. Returns nil when a section does not keep
    /// one tempo (played live): the beat-by-beat tracker handles those.
    static func steadyPins(drums: Onsets.Hits, grid: Grid, p0: Double, duration: Double) -> [(Double, Double)]? {
        guard drums.times.count > 32, let maxW = drums.weights.max(), maxW > 0 else { return nil }
        let sortedW = drums.weights.sorted()
        let main = sortedW[Int(Double(sortedW.count - 1) * 0.9)]
        // Real drum hits only (not ghost notes or bleed).
        let hits = zip(drums.times, drums.weights).filter { $0.1 >= main * 0.25 }.map { (t: $0.0, w: $0.1) }
        guard hits.count > 32 else { return nil }
        // Sections: split where the drums pause for a while.
        let gap = max(3.0, 6 * p0)
        var sections: [[(t: Double, w: Float)]] = [[hits[0]]]
        for h in hits.dropFirst() {
            if h.t - sections[sections.count - 1].last!.t > gap { sections.append([h]) } else { sections[sections.count - 1].append(h) }
        }
        struct Line { var a: Double; var p: Double; var first: Double; var last: Double; var hits: [(t: Double, w: Float)] }
        func fitLine(_ sec: [(t: Double, w: Float)]) -> Line? {
            var bestLine: Line?, bestScore: Float = 0
            // Try the first hits as the beat phase; the line that catches the most hit weight wins.
            for cand in sec.prefix(8) {
                var a = cand.t, p = p0, ok = true
                for window in [0.2, 0.14, 0.1, 0.08] {
                    let pts = sec.compactMap { h -> (b: Double, t: Double, w: Double)? in
                        let bf = (h.t - a) / p, b = bf.rounded()
                        return abs(bf - b) <= window ? (b, h.t, Double(h.w)) : nil
                    }
                    guard pts.count >= 6 else { ok = false; break }
                    var sw = 0.0, sb = 0.0, st = 0.0
                    for x in pts { sw += x.w; sb += x.w * x.b; st += x.w * x.t }
                    let mb = sb / sw, mt = st / sw
                    var num = 0.0, den = 0.0
                    for x in pts { num += x.w * (x.b - mb) * (x.t - mt); den += x.w * (x.b - mb) * (x.b - mb) }
                    if den > 0 { p = num / den; a = mt - p * mb } else if pts.count > 1 { ok = false; break }
                }
                guard ok, abs(p / p0 - 1) < 0.06 else { continue }
                let score = sec.filter { h in let bf = (h.t - a) / p; return abs(bf - bf.rounded()) <= 0.08 }.map(\.w).reduce(0, +)
                if score > bestScore { bestScore = score; bestLine = Line(a: a, p: p, first: sec.first!.t, last: sec.last!.t, hits: sec) }
            }
            return bestLine
        }
        var lines: [Line] = []
        for sec in sections where sec.count >= 8 {
            guard let l = fitLine(sec) else { return nil }
            // One tempo in this section: most of its strong hits sit on the line (off-beat hits are fine, smeared ones are not).
            let strong = sec.filter { $0.w >= main * 0.5 }
            let onLine = strong.filter { h in let bf = (h.t - l.a) / l.p; let d = abs(bf - bf.rounded()); return d <= 0.08 || abs(d - 0.5) <= 0.08 }
            guard strong.count < 6 || Double(onLine.count) / Double(strong.count) >= 0.7 else { return nil }
            lines.append(l)
        }
        guard !lines.isEmpty, lines.map({ $0.last - $0.first }).reduce(0, +) > 0.3 * duration else { return nil }
        // Number the beats: the biggest section from the grid's own numbering, the others counted across the gaps.
        let mainIdx = lines.indices.max { lines[$0].hits.count < lines[$1].hits.count }!
        var offset = [Double](repeating: 0, count: lines.count)   // beat number = k + offset[i], k counted on line i from its a
        offset[mainIdx] = (grid.beat(at: lines[mainIdx].a) - grid.firstBarBeat).rounded()
        func lastK(_ l: Line) -> Double { ((l.last - l.a) / l.p).rounded() }
        func firstK(_ l: Line) -> Double { ((l.first - l.a) / l.p).rounded() }
        if mainIdx + 1 < lines.count {
            for i in (mainIdx + 1)..<lines.count {
                let prev = lines[i - 1], cur = lines[i]
                let endT = prev.a + prev.p * lastK(prev), startT = cur.a + cur.p * firstK(cur)
                let n = ((startT - endT) / ((prev.p + cur.p) / 2)).rounded()
                offset[i] = lastK(prev) + offset[i - 1] + n - firstK(cur)
            }
        }
        if mainIdx > 0 {
            for i in stride(from: mainIdx - 1, through: 0, by: -1) {
                let next = lines[i + 1], cur = lines[i]
                let startT = next.a + next.p * firstK(next), endT = cur.a + cur.p * lastK(cur)
                let n = ((startT - endT) / ((next.p + cur.p) / 2)).rounded()
                offset[i] = firstK(next) + offset[i + 1] - n - lastK(cur)
            }
        }
        // Pins: each beat at its strongest hit near the line.
        var best: [Double: (t: Double, w: Float)] = [:]
        for (i, l) in lines.enumerated() {
            for h in l.hits {
                let bf = (h.t - l.a) / l.p, k = bf.rounded()
                guard abs(bf - k) <= 0.08 else { continue }
                let b = k + offset[i]
                if (best[b]?.w ?? -1) < h.w { best[b] = (h.t, h.w) }
            }
        }
        let pins = best.map { ($0.key, $0.value.t) }.sorted { $0.0 < $1.0 }
        return pins.count >= 16 ? pins : nil
    }
}
