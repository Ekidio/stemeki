import Foundation

/// The beat grid from a trained beat/downbeat model (Beat This!, run on the whole mix), the way DJ apps and
/// Logic's Smart Tempo find it: every beat of the song, the 1 included, decided over the whole song at once.
/// The model works in 20 ms frames; each beat is moved onto its real attack, then every stretch that keeps one
/// tempo becomes one perfectly straight line (a round BPM when the hits allow it). Where the tempo really moves,
/// every beat keeps its own marker.
enum SmartTempo {
    // Tuning (STEMEKI_ST_* override them for measurements).
    private static func env(_ k: String, _ d: Double) -> Double { Double(ProcessInfo.processInfo.environment["STEMEKI_ST_" + k] ?? "") ?? d }
    static var biasFix: Bool { env("BIAS", 1) != 0 }
    static var refineWindow: Double { env("WIN", 0.035) }
    static var smoothHalf: Int { Int(env("HALF", 4)) }

    /// Warp markers numbered from the first downbeat (beat 0 = bar 1).
    static func map(beats raw: [Double], downbeats: [Double], hits: [StemKind: Onsets.Hits]) -> [BeatPoint]? {
        guard raw.count >= 16 else { return nil }
        let beats = refine(raw, hits: hits)
        // Numbering: the beat nearest the first downbeat is 0.
        let zero: Int = {
            guard let d = downbeats.first else { return 0 }
            return beats.indices.min { abs(raw[$0] - d) < abs(raw[$1] - d) } ?? 0
        }()
        let pts = beats.enumerated().map { (b: Double($0.offset - zero), t: $0.element) }
        if env("STRAIGHT", 1) == 0 { return pts.map { BeatPoint(beat: $0.b, time: $0.t) } }
        return straighten(pts).map { BeatPoint(beat: $0.b, time: $0.t) }
    }

    /// Each model beat to the attack it stands for: the strongest drum hit within ±35 ms, or a hit of another
    /// stem when the drums are silent there; without one the model's time stays.
    static func refine(_ beats: [Double], hits: [StemKind: Onsets.Hits]) -> [Double] {
        func strongest(_ h: Onsets.Hits?, near t: Double, window: Double, floor: Float) -> Double? {
            guard let h, !h.times.isEmpty else { return nil }
            var lo = 0, hi = h.times.count
            while lo < hi { let m = (lo + hi) / 2; if h.times[m] < t - window { lo = m + 1 } else { hi = m } }
            var best: (t: Double, s: Double)?
            var i = lo
            while i < h.times.count && h.times[i] <= t + window {
                if h.weights[i] >= floor {
                    let s = Double(h.weights[i]) * (1 - 0.5 * abs(h.times[i] - t) / window)
                    if s > (best?.s ?? 0) { best = (h.times[i], s) }
                }
                i += 1
            }
            return best?.t
        }
        func mainLevel(_ h: Onsets.Hits?) -> Float {
            guard let h, !h.weights.isEmpty else { return 0 }
            let w = h.weights.sorted()
            return w[Int(Double(w.count - 1) * 0.9)]
        }
        let drums = hits[.drums], dMain = mainLevel(drums)
        let others: [(Onsets.Hits, Float)] = [StemKind.bass, .other, .vocals].compactMap { k in hits[k].map { ($0, mainLevel($0)) } }
        // The model's beats can sit a steady few tens of ms off the attacks (its 20 ms frames, the mix it hears):
        // measure that offset over the whole song first, so the search below is centred on the real hits.
        var shift = 0.0
        if biasFix, let d = drums, d.times.count > 16 {
            var offs: [Double] = []
            for t in beats { if let h = strongest(d, near: t, window: 0.07, floor: dMain * 0.3) { offs.append(h - t) } }
            if offs.count >= 16 { offs.sort(); shift = offs[offs.count / 2] }
        }
        let w = refineWindow
        return beats.map { t0 in
            let t = t0 + shift
            if let d = strongest(drums, near: t, window: w, floor: dMain * 0.15) { return d }
            for (h, m) in others { if let o = strongest(h, near: t, window: w * 0.85, floor: m * 0.25) { return o } }
            return t
        }
    }

    private struct Line { var a: Double; var p: Double }

    /// Least-squares line through the beats, then again without the worst tenth (a syncopated or doubled
    /// attack must not tilt it). Returns the line, the median and the 90th-percentile distance.
    private static func fit(_ x: ArraySlice<(b: Double, t: Double)>, period: Double? = nil) -> (line: Line, med: Double, max: Double, drift: Double) {
        let first = fitOnce(x, period: period)
        guard x.count >= 10 else { return first }
        let keep = x.sorted { abs($0.t - (first.line.a + first.line.p * $0.b)) < abs($1.t - (first.line.a + first.line.p * $1.b)) }
            .prefix(Int(Double(x.count) * 0.9))
        let l = fitOnce(ArraySlice(keep), period: period).line
        let r = x.map { abs($0.t - (l.a + l.p * $0.b)) }.sorted()
        return (l, r[r.count / 2], r[Int(Double(r.count - 1) * 0.9)], drift(x, l))
    }

    /// How far the beats wander away from the line on their way through it: the residuals smoothed over
    /// 9 beats (a single attack's jitter averages out, a tempo that differs from the line does not).
    private static func drift(_ x: ArraySlice<(b: Double, t: Double)>, _ l: Line) -> Double {
        let r = x.map { $0.t - (l.a + l.p * $0.b) }
        guard r.count >= 9 else { return 0 }
        var worst = 0.0
        for i in 0...(r.count - 9) {
            let w = r[i..<(i + 9)].sorted()
            worst = max(worst, abs(w[4]))
        }
        return worst
    }

    private static func fitOnce(_ x: ArraySlice<(b: Double, t: Double)>, period: Double? = nil) -> (line: Line, med: Double, max: Double, drift: Double) {
        let n = Double(x.count)
        let mb = x.map(\.b).reduce(0, +) / n, mt = x.map(\.t).reduce(0, +) / n
        var p = period ?? 0
        if period == nil {
            var num = 0.0, den = 0.0
            for v in x { num += (v.b - mb) * (v.t - mt); den += (v.b - mb) * (v.b - mb) }
            p = den > 0 ? num / den : 0.5
        }
        let a = mt - p * mb
        let r = x.map { abs($0.t - (a + p * $0.b)) }.sorted()
        return (Line(a: a, p: p), r[r.count / 2], r.last ?? 0, 0)
    }

    /// Stretches of one tempo become straight lines (two markers each); short or wandering stretches keep a
    /// marker on every beat.
    static func straighten(_ pts: [(b: Double, t: Double)]) -> [(b: Double, t: Double)] {
        // A single attack may jitter (tolMax, tolMed), but the beats must not wander off the line (tolDrift):
        // that is a tempo the line does not have, and it would be heard as drift.
        let tolMax = 0.022, tolMed = 0.010, tolDrift = 0.005, minRun = 16
        func holds(_ f: (line: Line, med: Double, max: Double, drift: Double)) -> Bool {
            f.max <= tolMax && f.med <= tolMed && f.drift <= tolDrift
        }
        var out: [(b: Double, t: Double)] = []
        var runs: [(Int, Int)] = []   // straight runs [s, e); (-1, i) = a single beat keeping its own marker
        var s = 0
        while s < pts.count {
            // Grow the run as long as one straight line still holds its beats.
            var e = min(pts.count, s + minRun)
            guard e - s >= minRun, holds(fit(pts[s..<e])) else {
                runs.append((-1, s)); s += 1; continue
            }
            var step = 64
            while step >= 1 {
                while e + step <= pts.count {
                    let f = fit(pts[s..<(e + step)])
                    if holds(f) { e += step } else { break }
                }
                step /= 2
            }
            runs.append((s, e))
            s = e
        }
        // Neighbouring runs that one line holds just as well become one (the same tempo on both sides of a break).
        var merged: [(Int, Int)] = []
        for r in runs {
            if let last = merged.last, r.0 >= 0, last.0 >= 0, last.1 == r.0 {
                let f = fit(pts[last.0..<r.1])
                if holds(f) { merged[merged.count - 1] = (last.0, r.1); continue }
            }
            merged.append(r)
        }
        for (s, e) in merged {
            // A beat outside the straight runs follows the tempo of its neighbours: a line through the 9 beats
            // around it (a single attack's jitter evens out, a tempo that moves is followed).
            guard s >= 0 else {
                let half = smoothHalf
                let lo = max(0, e - half), hi = min(pts.count, e + half + 1)
                if half > 0, hi - lo >= 5 {
                    let l = fitOnce(pts[lo..<hi]).line
                    out.append((pts[e].b, l.a + l.p * pts[e].b))
                } else {
                    out.append(pts[e])
                }
                continue
            }
            var f = fit(pts[s..<e])
            // Studio tempos are round: a whole (or half) BPM when the beats agree just as well.
            let bpm = 60 / f.line.p
            for cand in [bpm.rounded(), (bpm * 2).rounded() / 2] where abs(cand - bpm) < 0.03 {
                let g = fit(pts[s..<e], period: 60 / cand)
                if holds(g) && g.med <= f.med + 0.002 { f = g; break }
            }
            let b0 = pts[s].b, b1 = pts[e - 1].b
            out.append((b0, f.line.a + f.line.p * b0))
            out.append((b1, f.line.a + f.line.p * b1))
        }
        return out.sorted { $0.b < $1.b }
    }
}
