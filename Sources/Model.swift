import Foundation
import SwiftUI

/// The four sources Demucs (htdemucs) writes for every song.
enum StemKind: String, CaseIterable, Codable, Sendable {
    case vocals, drums, bass, other

    /// The four Demucs stems.
    static let separated: [StemKind] = [.vocals, .drums, .bass, .other]

    var fileName: String { rawValue + ".wav" }
}

/// A row on screen: one stem, or several summed (the 2-stem "instrumental").
struct Lane: Identifiable, Hashable {
    let id: String
    let title: String       // shown in the UI
    let fileTag: String     // used in exported file names
    let color: Color
    let stems: [StemKind]

    static let vocals = Lane(id: "vocals", title: "VOCALS", fileTag: "VOCALS", color: Theme.vocals, stems: [.vocals])
    static let drums = Lane(id: "drums", title: "DRUMS", fileTag: "DRUMS", color: Theme.drums, stems: [.drums])
    static let bass = Lane(id: "bass", title: "BASS", fileTag: "BASS", color: Theme.bass, stems: [.bass])
    static let other = Lane(id: "other", title: "INSTRUMENTS", fileTag: "INSTRUMENTS", color: Theme.other, stems: [.other])
    /// The whole song (all four stems together = the original mix).
    static let full = Lane(id: "mix", title: "MIX", fileTag: "MIX", color: Theme.mix, stems: [.vocals, .drums, .bass, .other])
    static let instrumental = Lane(id: "instrumental", title: "INSTRUMENTAL", fileTag: "INSTRUMENTAL", color: Theme.instrumental,
                                   stems: [.drums, .bass, .other])

    static let all: [Lane] = [.full, .vocals, .drums, .bass, .other, .instrumental]

    static func lanes(for mode: StemMode) -> [Lane] {
        switch mode {
        case .mix: return [.full]
        case .four: return [.vocals, .drums, .bass, .other]
        case .two: return [.vocals, .instrumental]
        }
    }
}

enum StemMode: String, CaseIterable, Codable {
    case mix, two, four
    var label: String {
        switch self {
        case .mix: return "MIX"
        case .two: return "2 STEMS"
        case .four: return "4 STEMS"
        }
    }
}

enum SongState: String, Codable {
    case queued, separating, analyzing, ready, failed
}

struct Song: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var sourcePath: String
    var addedAt = Date()
    var state: SongState = .queued
    var error: String?

    // The original file's format: loops are exported in it.
    var srcExt: String
    var srcSampleRate: Double
    var srcBits: Int
    var srcFloat: Bool
    var srcChannels: Int

    // Analysis (the auto values are kept so a manual change can be undone).
    var duration: Double?
    var bpm: Double?
    var downbeat: Double?
    var drumStart: Double?
    var key: String?
    var camelot: String?
    var autoBpm: Double?
    var autoDownbeat: Double?
    /// Warp markers: beat number → time in the audio. Beat 0 is "the 1" the bars are counted from.
    /// One point = constant tempo (`bpm`); more points = the grid follows the music between them.
    var beatMap: [BeatPoint]?
    /// Tempo the exported loops are stretched to (nil = the song's tempo rounded).
    var targetBpm: Double?
    /// MIX / 2 STEMS / 4 STEMS view for this song (new songs open in MIX).
    var viewMode: StemMode?
    /// Bar regions marked on the lanes, exported together.
    var regions: [Region]?
    /// Edited audio: cut pieces per lane. A lane without clips plays the song as it is.
    var clips: [Clip]?
    /// NUDGE: how many beats the music has been moved against the grid (positive = later).
    var contentShift: Double?
    /// AUTO WARP has run once for this song.
    var autoWarped: Bool?

    // Last loop, so a song reopens where it was left.
    var loopStartBar: Int?
    var loopBars: Int?
    var loopWhole: Bool?

    var grid: Grid? {
        guard let bpm, let duration, bpm > 20 else { return nil }
        if let map = beatMap, !map.isEmpty { return Grid(points: map, bpm: bpm, duration: duration) }
        guard let downbeat else { return nil }
        return Grid(points: [BeatPoint(beat: 0, time: downbeat)], bpm: bpm, duration: duration)
    }

    var isReady: Bool { state == .ready }
}

struct BeatPoint: Codable, Equatable, Sendable {
    var beat: Double
    var time: Double
}

/// 4/4 bar grid laid over the audio through warp markers. Between two markers the tempo is
/// constant; outside them it continues with the nearest segment's tempo (or `bpm` with one marker).
/// Bars are counted from beat 0 ("the 1") backwards to the start and forwards to the end.
struct Grid: Equatable, Sendable {
    private(set) var points: [BeatPoint]
    var bpm: Double            // tempo used when there is only one marker
    var duration: Double
    private(set) var firstBarBeat: Double = 0

    init(points: [BeatPoint], bpm: Double, duration: Double) {
        var pts = points.sorted { $0.beat < $1.beat }
        // Times must rise with the beats.
        var clean: [BeatPoint] = []
        for p in pts where clean.last.map({ p.beat > $0.beat + 1e-9 && p.time > $0.time + 1e-4 }) ?? true { clean.append(p) }
        pts = clean.isEmpty ? [BeatPoint(beat: 0, time: 0)] : clean
        self.points = pts
        self.bpm = bpm
        self.duration = duration
        // Bar 1: the earliest downbeat (multiple of 4 beats from the 1) at, or a hair before, 0 s.
        var m = 0.0
        var guardCount = 0
        while time(m - 4) >= -0.02 && guardCount < 4000 { m -= 4; guardCount += 1 }
        while time(m) < -0.02 && guardCount < 8000 { m += 4; guardCount += 1 }
        firstBarBeat = m
    }

    static func straight(bpm: Double, anchor: Double, duration: Double) -> Grid {
        Grid(points: [BeatPoint(beat: 0, time: anchor)], bpm: bpm, duration: duration)
    }

    /// Seconds per beat of the first and last segments (used past the ends).
    private var headSlope: Double {
        points.count >= 2 ? (points[1].time - points[0].time) / (points[1].beat - points[0].beat) : 60 / bpm
    }
    private var tailSlope: Double {
        let n = points.count
        return n >= 2 ? (points[n - 1].time - points[n - 2].time) / (points[n - 1].beat - points[n - 2].beat) : 60 / bpm
    }

    func time(_ b: Double) -> Double {
        let f = points[0], l = points[points.count - 1]
        if b <= f.beat { return f.time + (b - f.beat) * headSlope }
        if b >= l.beat { return l.time + (b - l.beat) * tailSlope }
        var lo = 0, hi = points.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if points[mid].beat <= b { lo = mid } else { hi = mid }
        }
        let a = points[lo], c = points[hi]
        return a.time + (b - a.beat) / (c.beat - a.beat) * (c.time - a.time)
    }

    func beat(at t: Double) -> Double {
        let f = points[0], l = points[points.count - 1]
        if t <= f.time { return f.beat + (t - f.time) / headSlope }
        if t >= l.time { return l.beat + (t - l.time) / tailSlope }
        var lo = 0, hi = points.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if points[mid].time <= t { lo = mid } else { hi = mid }
        }
        let a = points[lo], c = points[hi]
        return a.beat + (t - a.time) / (c.time - a.time) * (c.beat - a.beat)
    }

    /// Average tempo over the whole song.
    var meanBPM: Double {
        let b0 = beat(at: 0), b1 = beat(at: max(duration, 1))
        return 60 * (b1 - b0) / max(duration, 1)
    }

    /// True when the grid has one tempo everywhere.
    var isStraight: Bool {
        guard points.count > 2 else { return true }
        let s0 = (points[1].time - points[0].time) / (points[1].beat - points[0].beat)
        for i in 1..<(points.count - 1) {
            let s = (points[i + 1].time - points[i].time) / (points[i + 1].beat - points[i].beat)
            if abs(s - s0) > 1e-6 { return false }
        }
        return true
    }

    // Approximate sizes for zooming and drawing decisions.
    var beat: Double { 60 / meanBPM }
    var bar: Double { 4 * beat }
    var anchor: Double { time(0) }

    func barStart(_ n: Int) -> Double { time(firstBarBeat + Double(n - 1) * 4) }
    var firstBar: Double { barStart(1) }
    func barBeat(_ n: Int) -> Double { firstBarBeat + Double(n - 1) * 4 }

    /// Bar number (1-based) containing time t; 0 or less before bar 1.
    func barIndex(at t: Double) -> Int { Int(floor((beat(at: t) - firstBarBeat) / 4)) + 1 }

    /// Nearest bar line to t, as a bar number.
    func nearestBarLine(_ t: Double) -> Int { Int(((beat(at: t) - firstBarBeat) / 4).rounded()) + 1 }

    /// Number of complete bars in the song.
    var fullBars: Int { max(0, Int(floor((beat(at: duration + 0.001) - firstBarBeat) / 4))) }

    /// Local seconds per beat at time t.
    func beatLength(at t: Double) -> Double {
        let b = beat(at: t)
        return time(floor(b) + 1) - time(floor(b))
    }

    /// "17.3" style position (bar.beat).
    func position(_ t: Double) -> (bar: Int, beat: Int) {
        let beats = Int(floor(beat(at: t + 0.01) - firstBarBeat))
        let b = beats >= 0 ? beats / 4 + 1 : (beats - 3) / 4 + 1
        let k = ((beats % 4) + 4) % 4 + 1
        return (b, k)
    }
}

/// Positions on the timeline are counted in beats from the start of bar 1 (beat 0 = bar 1's downbeat).
/// A range marked on one lane (stem): a region to cut or export.
struct Region: Codable, Identifiable, Equatable {
    var id = UUID()
    var laneId: String
    var start: Int      // beats
    var len: Int        // beats

    var end: Int { start + len } // exclusive

    init(id: UUID = UUID(), laneId: String, start: Int, len: Int) {
        self.id = id; self.laneId = laneId; self.start = start; self.len = len
    }

    private enum K: String, CodingKey { case id, laneId, start, len, startBar, bars }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = try c.decode(UUID.self, forKey: .id)
        laneId = try c.decode(String.self, forKey: .laneId)
        if let s = try c.decodeIfPresent(Int.self, forKey: .start) {
            start = s; len = try c.decode(Int.self, forKey: .len)
        } else {  // saved in bars by an earlier version
            start = (try c.decode(Int.self, forKey: .startBar) - 1) * 4
            len = try c.decode(Int.self, forKey: .bars) * 4
        }
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encode(id, forKey: .id); try c.encode(laneId, forKey: .laneId)
        try c.encode(start, forKey: .start); try c.encode(len, forKey: .len)
    }
}

/// A piece of a lane's audio placed on the timeline: song beats [src, src+len), heard at
/// beats [start, start+len). Later clips lie on top of earlier ones.
struct Clip: Codable, Identifiable, Equatable {
    var id = UUID()
    var laneId: String
    var start: Int
    var src: Int
    var len: Int

    var end: Int { start + len }

    init(id: UUID = UUID(), laneId: String, start: Int, src: Int, len: Int) {
        self.id = id; self.laneId = laneId; self.start = start; self.src = src; self.len = len
    }

    private enum K: String, CodingKey { case id, laneId, start, src, len, startBar, srcBar, bars }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = try c.decode(UUID.self, forKey: .id)
        laneId = try c.decode(String.self, forKey: .laneId)
        if let s = try c.decodeIfPresent(Int.self, forKey: .start) {
            start = s; src = try c.decode(Int.self, forKey: .src); len = try c.decode(Int.self, forKey: .len)
        } else {  // saved in bars by an earlier version
            start = (try c.decode(Int.self, forKey: .startBar) - 1) * 4
            src = (try c.decode(Int.self, forKey: .srcBar) - 1) * 4
            len = try c.decode(Int.self, forKey: .bars) * 4
        }
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encode(id, forKey: .id); try c.encode(laneId, forKey: .laneId)
        try c.encode(start, forKey: .start); try c.encode(src, forKey: .src); try c.encode(len, forKey: .len)
    }
}

/// A run of beats of an edited lane: timeline beats [tl, tl+len) play song beats [src, …).
struct Seg: Equatable, Sendable {
    var tl: Int
    var src: Int
    var len: Int
}

extension Array where Element == Clip {
    /// The audible pieces after stacking (later clips win), merged into runs.
    func segments(for laneId: String) -> [Seg]? {
        let list = filter { $0.laneId == laneId }
        guard !list.isEmpty else { return nil }
        let lo = list.map(\.start).min()!, hi = list.map(\.end).max()!
        var segs: [Seg] = []
        for b in lo..<hi {
            guard let c = list.last(where: { b >= $0.start && b < $0.end }) else { continue }
            let src = b - c.start + c.src
            if var last = segs.last, last.tl + last.len == b, last.src + last.len == src {
                last.len += 1
                segs[segs.count - 1] = last
            } else {
                segs.append(Seg(tl: b, src: src, len: 1))
            }
        }
        return segs
    }
}

extension Grid {
    /// Time of position p (beats from bar 1).
    func posTime(_ p: Int) -> Double { time(firstBarBeat + Double(p)) }

    /// Position (beats from bar 1, fractional) at time t.
    func pos(at t: Double) -> Double { beat(at: t) - firstBarBeat }

    /// "4" for a bar start, "4.3" for its third beat.
    func posLabel(_ p: Int) -> String {
        let bar = Int(floor(Double(p) / 4)) + 1, beat = ((p % 4) + 4) % 4 + 1
        return beat == 1 ? "\(bar)" : "\(bar).\(beat)"
    }

    /// "4–7" for whole bars, "4.1–4.2" for beats (last beat inclusive).
    func rangeLabel(_ start: Int, _ end: Int) -> String {
        if start % 4 == 0 && end % 4 == 0 { return "\(start / 4 + 1)–\(end / 4)" }
        let lastBar = Int(floor(Double(end - 1) / 4)) + 1, lastBeat = (((end - 1) % 4) + 4) % 4 + 1
        let firstBar = Int(floor(Double(start) / 4)) + 1, firstBeat = ((start % 4) + 4) % 4 + 1
        return "\(firstBar).\(firstBeat)–\(lastBar).\(lastBeat)"
    }

    /// Song time heard at timeline time t on a lane with these segments (nil = silence).
    func sourceTime(_ t: Double, _ segs: [Seg]?) -> Double? {
        guard let segs else { return t }
        let b = beat(at: t)
        return sourceBeat(b, segs).map { time($0) }
    }

    /// Same in beats: the song beat heard at timeline beat b (nil = silence).
    func sourceBeat(_ b: Double, _ segs: [Seg]?) -> Double? {
        guard let segs else { return b }
        let p = b - firstBarBeat
        for s in segs where p >= Double(s.tl) && p < Double(s.tl + s.len) {
            return b + Double(s.src - s.tl)
        }
        return nil
    }
}

struct LoopSelection: Equatable {
    var startBar: Int
    var bars: Int
    var whole = false

    var endBar: Int { startBar + bars } // exclusive
}

enum Theme {
    static let bg = Color(red: 0.055, green: 0.058, blue: 0.072)
    static let panel = Color(red: 0.085, green: 0.089, blue: 0.108)
    static let panel2 = Color(red: 0.115, green: 0.12, blue: 0.145)
    static let line = Color.white.opacity(0.07)
    static let text = Color(red: 0.86, green: 0.87, blue: 0.92)
    static let dim = Color(red: 0.52, green: 0.54, blue: 0.62)
    static let loop = Color(red: 1.0, green: 0.84, blue: 0.04)
    static let accent = Color(red: 0.27, green: 0.85, blue: 0.98)

    static let vocals = Color(red: 1.0, green: 0.36, blue: 0.54)
    static let drums = Color(red: 1.0, green: 0.66, blue: 0.13)
    static let bass = Color(red: 0.24, green: 0.86, blue: 0.59)
    static let other = Color(red: 0.36, green: 0.66, blue: 1.0)
    static let instrumental = Color(red: 0.62, green: 0.49, blue: 1.0)
    static let mix = Color(red: 0.74, green: 0.78, blue: 0.92)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

func formatTime(_ t: Double) -> String {
    let t = max(0, t)
    let m = Int(t) / 60
    let s = t - Double(m * 60)
    return String(format: "%d:%05.2f", m, s)
}

/// "+1½ beat", "−2 bar"…
func formatShift(_ beats: Double) -> String {
    let sign = beats > 0 ? "+" : "−"
    let a = abs(beats)
    let bars = Int(a / 4)
    let rest = a - Double(bars * 4)
    let whole = Int(rest)
    let half = rest - Double(whole) >= 0.5
    var parts: [String] = []
    if bars > 0 { parts.append("\(bars) bar") }
    if rest > 1e-9 { parts.append((whole == 0 ? "" : "\(whole)") + (half ? "½" : "") + " beat") }
    return sign + (parts.isEmpty ? "0" : parts.joined(separator: " "))
}

func formatBPM(_ bpm: Double) -> String {
    abs(bpm - bpm.rounded()) < 0.005 ? String(format: "%.0f", bpm) : String(format: "%.2f", bpm)
}
