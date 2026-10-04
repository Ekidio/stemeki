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

        var beats = track(1) + track(-1).dropFirst()
        beats.sort { $0.0 < $1.0 }

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
}
