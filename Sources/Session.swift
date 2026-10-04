import Foundation
import AppKit
import SwiftUI

/// State of the open song: lanes, mixer, loop, grid edits, zoom and export.
@MainActor
final class Session: ObservableObject {
    struct LaneState {
        var gain: Float = 1
        var mute = false
        var solo = false
        var export = true
    }

    let library: Library
    let player = StemPlayer()

    @Published var mode: StemMode {
        didSet {
            if let id = song?.id, song?.viewMode != mode { library.update(id) { $0.viewMode = mode } }
            selected = []
            applyGains(); syncArrangement()
        }
    }
    @Published var laneStates: [String: LaneState] = [:] { didSet { applyGains() } }
    @Published var loop: LoopSelection? { didSet { loopChanged() } }
    @Published var loopEnabled = true { didSet { loopChanged() } }
    /// NUDGE step in beats (½ beat, 1 beat, ½ bar, 1 bar).
    @Published var nudgeStep: Double = 0.5 { didSet { UserDefaults.standard.set(nudgeStep, forKey: "nudgeStep") } }
    @Published var follow = true
    @Published var selected: Set<UUID> = []
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    private struct Snapshot {
        var regions: [Region]
        var clips: [Clip]?
    }
    @Published var clickOn = false { didSet { player.setClick(clickOn) } }

    // Visible time window.
    @Published var viewStart: Double = 0
    @Published var viewLength: Double = 30

    // Export options.
    @Published var exportMix = false { didSet { UserDefaults.standard.set(exportMix, forKey: "exportMix") } }
    @Published var exportSeparate = true { didSet { UserDefaults.standard.set(exportSeparate, forKey: "exportSeparate") } }
    @Published var fadeOn = false
    @Published var fadeMs: Double = 3 { didSet { UserDefaults.standard.set(fadeMs, forKey: "fadeMs") } }
    @Published var toast: Toast?
    @Published var exporting = false

    struct Toast: Equatable {
        var text: String
        var files: [URL]
        var isError = false
    }

    /// The open session, for app-wide keys.
    static weak var current: Session?

    init(library: Library) {
        self.library = library
        let d = UserDefaults.standard
        mode = .mix
        exportMix = d.bool(forKey: "exportMix")
        exportSeparate = d.object(forKey: "exportSeparate") as? Bool ?? true
        fadeMs = d.object(forKey: "fadeMs") as? Double ?? 3
        nudgeStep = d.object(forKey: "nudgeStep") as? Double ?? 0.5
        // Fade is off on every launch, on purpose.
        fadeOn = false
        Session.current = self
    }

    var song: Song? { library.selected }
    var grid: Grid? { song?.grid }
    var lanes: [Lane] { Lane.lanes(for: mode) }
    var duration: Double { player.duration > 0 ? player.duration : (song?.duration ?? 0) }

    func state(_ lane: Lane) -> LaneState { laneStates[lane.id] ?? LaneState() }

    func setState(_ lane: Lane, _ change: (inout LaneState) -> Void) {
        var s = state(lane)
        change(&s)
        laneStates[lane.id] = s
    }

    func isAudible(_ lane: Lane) -> Bool {
        let s = state(lane)
        if s.mute { return false }
        let anySolo = lanes.contains { state($0).solo }
        return !anySolo || s.solo
    }

    // MARK: Song switching

    func open(_ song: Song?) {
        guard let song, song.isReady else {
            player.unload()
            loop = nil
            return
        }
        guard player.loadedID != song.id else { return }
        player.load(song: song, dir: library.stemsDir(song))
        // Every song starts as one waveform (MIX); stems come in when asked for.
        mode = song.viewMode ?? .mix
        if let start = song.loopStartBar, let bars = song.loopBars {
            loop = LoopSelection(startBar: start, bars: bars, whole: song.loopWhole ?? false)
        } else {
            loop = nil
        }
        let d = duration
        if let g = song.grid {
            // Start with about 16 bars on screen, from where the drums come in.
            viewLength = min(d, g.bar * 16)
            let s = (song.drumStart ?? 0) - g.bar
            viewStart = max(0, min(s, d - viewLength))
        } else {
            viewLength = min(d, 30)
            viewStart = 0
        }
        applyGains()
        syncPlayer()
    }

    // MARK: Mixer

    private func applyGains() {
        var g: [StemKind: Float] = [:]
        for kind in StemKind.allCases { g[kind] = 0 }
        for lane in lanes {
            let v = isAudible(lane) ? state(lane).gain : 0
            for k in lane.stems { g[k] = v }
        }
        player.setGains(g)
    }

    func soloOnly(_ ids: Set<String>) {
        for lane in lanes {
            setState(lane) { $0.solo = ids.contains(lane.id); $0.mute = false }
        }
    }

    func clearSoloMute() {
        for lane in lanes { setState(lane) { $0.solo = false; $0.mute = false } }
    }

    // MARK: Loop

    var loopRange: ClosedRange<Double>? {
        guard let loop, let g = grid else { return nil }
        let s = g.barStart(loop.startBar)
        let e = g.barStart(loop.endBar)
        return s...e
    }

    /// Tempo the loops are exported at: the chosen target, else the song's tempo rounded.
    var outputBPM: Double? {
        guard let g = grid else { return nil }
        return song?.targetBpm ?? g.meanBPM.rounded()
    }

    private func syncPlayer() {
        player.setGrid(grid)
        syncArrangement()
    }

    private func loopChanged() {
        syncPlayer()
        player.setLoop(loopRange, enabled: loopEnabled && loop != nil)
        guard let id = song?.id else { return }
        let l = loop
        library.update(id) { s in
            s.loopStartBar = l?.startBar
            s.loopBars = l?.bars
            s.loopWhole = l?.whole
        }
    }

    func clampLoop(_ l: LoopSelection) -> LoopSelection? {
        guard let g = grid, g.fullBars > 0 else { return nil }
        var l = l
        l.bars = max(1, min(l.bars, g.fullBars))
        l.startBar = max(1, min(l.startBar, g.fullBars - l.bars + 1))
        return l
    }

    func setLoopLength(_ bars: Int) {
        guard let g = grid else { return }
        let start = loop.map { $0.whole ? g.barIndex(at: player.position) : $0.startBar } ?? g.barIndex(at: player.position)
        loop = clampLoop(LoopSelection(startBar: max(1, start), bars: bars))
        loopEnabled = true
        if !player.isPlaying, let r = loopRange { player.seek(max(0, r.lowerBound)) }
    }

    func setWholeSong() {
        guard let g = grid, g.fullBars > 0 else { return }
        loop = LoopSelection(startBar: 1, bars: g.fullBars, whole: true)
        loopEnabled = true
    }

    func shiftLoop(_ dir: Int) {
        guard let l = loop, !l.whole else { return }
        if let n = clampLoop(LoopSelection(startBar: l.startBar + dir * l.bars, bars: l.bars)) {
            loop = n
            if let r = loopRange { player.seek(max(0, r.lowerBound)) }
        }
        revealLoop()
    }

    func halveLoop() { if let l = loop, l.bars > 1, !l.whole { loop = clampLoop(LoopSelection(startBar: l.startBar, bars: l.bars / 2)) } }
    func doubleLoop() { if let l = loop, !l.whole { loop = clampLoop(LoopSelection(startBar: l.startBar, bars: l.bars * 2)) } }

    /// Loop from a drag between two times, snapped outward to bar lines.
    func loopFromDrag(_ a: Double, _ b: Double) {
        guard let g = grid else { return }
        let lo = min(a, b), hi = max(a, b)
        let s = g.nearestBarLine(lo)
        let e = max(s + 1, g.nearestBarLine(hi))
        loop = clampLoop(LoopSelection(startBar: s, bars: e - s))
        loopEnabled = true
    }

    func revealLoop() {
        guard let r = loopRange else { return }
        if r.lowerBound < viewStart || r.upperBound > viewStart + viewLength {
            let len = r.upperBound - r.lowerBound
            if len > viewLength { viewLength = min(duration, len * 1.15) }
            viewStart = max(0, min(r.lowerBound - (viewLength - len) / 2, duration - viewLength))
        }
    }

    // MARK: Edits

    private var allRegions: [Region] { song?.regions ?? [] }
    private var allClips: [Clip] { song?.clips ?? [] }

    private func storeRegions(_ list: [Region]) {
        guard let id = song?.id else { return }
        library.update(id) { $0.regions = list }
    }

    private func storeClips(_ list: [Clip]) {
        guard let id = song?.id else { return }
        library.update(id) { $0.clips = list.isEmpty ? nil : list }
        syncArrangement()
    }

    /// Call before a change the user may want to undo.
    func checkpoint() {
        undoStack.append(Snapshot(regions: allRegions, clips: song?.clips))
        if undoStack.count > 60 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func restore(_ s: Snapshot) {
        guard let id = song?.id else { return }
        library.update(id) { $0.regions = s.regions; $0.clips = s.clips }
        syncArrangement()
        let ids = Set(s.regions.map(\.id) + (s.clips ?? []).map(\.id))
        selected = selected.filter { ids.contains($0) }
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(Snapshot(regions: allRegions, clips: song?.clips))
        restore(last)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(Snapshot(regions: allRegions, clips: song?.clips))
        restore(next)
    }

    // MARK: Edited audio (clips)

    /// Clips of the lanes on screen.
    var clips: [Clip] {
        let ids = Set(lanes.map(\.id))
        return allClips.filter { ids.contains($0.laneId) }
    }

    func segments(for laneId: String) -> [Seg]? { allClips.segments(for: laneId) }

    /// Tells the player which stems play edited pieces.
    func syncArrangement() {
        var a: [StemKind: [Seg]] = [:]
        for lane in lanes {
            if let s = segments(for: lane.id) { for k in lane.stems { a[k] = s } }
        }
        player.setArrangement(a)
    }

    /// A lane's first edit: one clip holding the whole song (pickup and tail bars included).
    private func clipsWithLane(_ laneId: String, _ list: [Clip]) -> [Clip] {
        guard let g = grid, !list.contains(where: { $0.laneId == laneId }) else { return list }
        return list + [Clip(laneId: laneId, startBar: 0, srcBar: 0, bars: g.fullBars + 2)]
    }

    /// Clicking inside a region: cut the lane's audio at its start and end. The piece between is selected.
    func cutAtRegion(_ rid: UUID) {
        guard let r = allRegions.first(where: { $0.id == rid }) else { return }
        checkpoint()
        var list = clipsWithLane(r.laneId, allClips)
        var inside: [UUID] = []
        var out: [Clip] = []
        for c in list {
            guard c.laneId == r.laneId, c.startBar < r.endBar, c.endBar > r.startBar else { out.append(c); continue }
            let cuts = [c.startBar, max(c.startBar, r.startBar), min(c.endBar, r.endBar), c.endBar]
            var first = true
            for k in 0..<3 where cuts[k + 1] > cuts[k] {
                var p = c
                if !first { p.id = UUID() }
                first = false
                p.srcBar = c.srcBar + (cuts[k] - c.startBar)
                p.startBar = cuts[k]
                p.bars = cuts[k + 1] - cuts[k]
                out.append(p)
                if k == 1 { inside.append(p.id) }
            }
        }
        list = out
        storeClips(list)
        storeRegions(allRegions.filter { $0.id != rid })
        selected = Set(inside)
    }

    /// Moves clips from their `base` state by whole bars (same lane).
    func moveClips(_ base: [Clip], bars: Int) {
        guard let g = grid else { return }
        var list = allClips
        for c in base {
            guard let i = list.firstIndex(where: { $0.id == c.id }) else { continue }
            list[i].startBar = max(0, min(c.startBar + bars, g.fullBars + 1))
        }
        if list != allClips { storeClips(list) }
    }

    // MARK: Regions

    /// Regions of the lanes on screen (2-stem and 4-stem have different lanes).
    var regions: [Region] {
        let ids = Set(lanes.map(\.id))
        return allRegions.filter { ids.contains($0.laneId) }
    }

    private func clampSpan(_ start: Int, _ bars: Int) -> (Int, Int)? {
        guard let g = grid, g.fullBars > 0 else { return nil }
        let n = max(1, min(bars, g.fullBars))
        return (max(1, min(start, g.fullBars - n + 1)), n)
    }

    @discardableResult
    func addRegion(lane: Lane, startBar: Int, bars: Int) -> UUID {
        let r = Region(laneId: lane.id, startBar: max(1, startBar), bars: max(1, bars))
        guard let (s, n) = clampSpan(r.startBar, r.bars) else { return r.id }
        var nr = r
        nr.startBar = s; nr.bars = n
        checkpoint()
        storeRegions(allRegions + [nr])
        selected = [nr.id]
        return nr.id
    }

    func setRegion(_ rid: UUID, startBar: Int, bars: Int) {
        guard let (s, n) = clampSpan(startBar, bars) else { return }
        var list = allRegions
        guard let i = list.firstIndex(where: { $0.id == rid }), list[i].startBar != s || list[i].bars != n else { return }
        list[i].startBar = s
        list[i].bars = n
        storeRegions(list)
    }

    /// Moves regions from their `base` state by whole bars and lanes (lane index within the lanes on screen).
    func moveRegions(_ base: [Region], bars: Int, lanes laneDelta: Int) {
        let ls = lanes
        var list = allRegions
        for r in base {
            guard let i = list.firstIndex(where: { $0.id == r.id }) else { continue }
            if let (s, n) = clampSpan(r.startBar + bars, r.bars) { list[i].startBar = s; list[i].bars = n }
            if let li = ls.firstIndex(where: { $0.id == r.laneId }) {
                list[i].laneId = ls[max(0, min(ls.count - 1, li + laneDelta))].id
            }
        }
        if list != allRegions { storeRegions(list) }
    }

    func deleteRegion(_ rid: UUID) {
        checkpoint()
        storeRegions(allRegions.filter { $0.id != rid })
        selected.remove(rid)
    }

    /// Delete: selected clips go silent, selected regions disappear.
    func deleteSelected() {
        guard !selected.isEmpty else { return }
        checkpoint()
        let sel = selected
        if allClips.contains(where: { sel.contains($0.id) }) { storeClips(allClips.filter { !sel.contains($0.id) }) }
        storeRegions(allRegions.filter { !sel.contains($0.id) })
        selected = []
    }

    /// Copies of the selected clips/regions; `place` = right after the selection (⌘D), else on top (⌥-drag).
    @discardableResult
    func duplicateSelected(place: Bool = true) -> (clips: [Clip], regions: [Region]) {
        let selC = clips.filter { selected.contains($0.id) }
        let selR = regions.filter { selected.contains($0.id) }
        guard !selC.isEmpty || !selR.isEmpty else { return ([], []) }
        let lo = (selC.map(\.startBar) + selR.map(\.startBar)).min()!
        let hi = (selC.map(\.endBar) + selR.map(\.endBar)).max()!
        let shift = place ? hi - lo : 0
        checkpoint()
        let newC = selC.map { c -> Clip in var n = c; n.id = UUID(); n.startBar += shift; return n }
        let newR = selR.map { r -> Region in
            var n = r; n.id = UUID()
            if let (s, b) = clampSpan(r.startBar + shift, r.bars) { n.startBar = s; n.bars = b }
            return n
        }
        if !newC.isEmpty { storeClips(allClips + newC) }   // later = on top
        if !newR.isEmpty { storeRegions(allRegions + newR) }
        selected = Set(newC.map(\.id) + newR.map(\.id))
        return (newC, newR)
    }

    func selectAll() { selected = Set(regions.map(\.id) + clips.filter { _ in true }.map(\.id)) }

    func clearRegions() {
        let ids = Set(regions.map(\.id))
        guard !ids.isEmpty else { return }
        checkpoint()
        storeRegions(allRegions.filter { !ids.contains($0.id) })
        selected = []
    }

    /// Back to the original audio on every lane on screen.
    func resetEdits() {
        let ids = Set(lanes.map(\.id))
        guard allClips.contains(where: { ids.contains($0.laneId) }) else { return }
        checkpoint()
        storeClips(allClips.filter { !ids.contains($0.laneId) })
        selected = []
    }

    // MARK: Grid edits

    /// Stores new warp markers (the first one is the 1, at beat 0). `live` edits come from a drag:
    /// playback is re-synced only when the drag ends.
    func setMap(_ points: [BeatPoint], bpm: Double? = nil, live: Bool = false) {
        guard let id = song?.id, let duration = song?.duration else { return }
        library.update(id) { s in
            if let bpm { s.bpm = max(40, min(250, bpm)) }
            let g = Grid(points: points, bpm: s.bpm ?? 120, duration: duration)
            s.beatMap = g.points
            s.downbeat = g.anchor
            if g.points.count > 1 { s.bpm = g.meanBPM }
        }
        if !live { loopChanged() }
    }

    func gridDragEnded() { loopChanged() }

    private var points: [BeatPoint] { grid?.points ?? [] }

    /// All transients of the given stems (or every stem), merged and sorted.
    func onsets(for stems: [StemKind]?) -> [Double] {
        let kinds = stems ?? StemKind.allCases
        return kinds.flatMap { player.onsets[$0] ?? [] }.sorted()
    }

    /// Nearest real hit to t (prefers the clicked lane, then the drums, then anything).
    func nearestHit(to t: Double, stems: [StemKind]?, maxDist: Double) -> Double? {
        if let stems, let h = Onsets.nearest(onsets(for: stems), to: t, maxDist: maxDist) { return h }
        if let h = Onsets.nearest(player.onsets[.drums] ?? [], to: t, maxDist: maxDist) { return h }
        return Onsets.nearest(onsets(for: nil), to: t, maxDist: maxDist)
    }

    /// AUTO WARP: follow the hits from the 1 and pin every bar.
    func autoWarp(rephase: Bool = false) {
        guard let g = grid, !player.hits.isEmpty else { return }
        // Track from the un-nudged 1, then put the nudge back on top.
        let shift = song?.contentShift ?? 0
        let base = Grid(points: g.points.map { BeatPoint(beat: $0.beat - shift, time: $0.time) }, bpm: g.bpm, duration: g.duration)
        let pts = AutoWarp.compute(hits: player.hits, grid: base, rephase: rephase)
        setMap(pts.map { BeatPoint(beat: $0.beat + shift, time: $0.time) })
        if let id = song?.id { library.update(id) { $0.autoWarped = true } }
    }

    /// NUDGE: moves the music against the grid by `beats` (positive = the music later / to the right).
    func nudge(_ beats: Double) {
        guard let g = grid, let id = song?.id else { return }
        library.update(id) { $0.contentShift = ($0.contentShift ?? 0) + beats }
        setMap(g.points.map { BeatPoint(beat: $0.beat + beats, time: $0.time) })
    }

    func resetNudge() {
        guard let sh = song?.contentShift, abs(sh) > 1e-9 else { return }
        nudge(-sh)
    }

    /// Typed BPM: the tempo the loops are exported at.
    func setBPM(_ bpm: Double) {
        guard let id = song?.id else { return }
        library.update(id) { $0.targetBpm = max(40, min(250, bpm)) }
    }

    func roundTarget() {
        guard let id = song?.id, let g = grid else { return }
        library.update(id) { $0.targetBpm = nil }
        _ = g
    }

    /// ×2 / ÷2: the grid counts twice / half as many beats.
    func scaleBPM(_ f: Double) {
        guard let g = grid else { return }
        setMap(g.points.map { BeatPoint(beat: $0.beat * f, time: $0.time) }, bpm: g.bpm * f)
        if let id = song?.id, let sh = song?.contentShift { library.update(id) { $0.contentShift = sh * f } }
        if let id = song?.id, let t = song?.targetBpm { library.update(id) { $0.targetBpm = t * f } }
    }

    /// Back to what the analysis found, then AUTO WARP.
    func resetGrid() {
        guard let s = song, let b = s.autoBpm, let d = s.autoDownbeat else { return }
        library.update(s.id) { $0.targetBpm = nil; $0.contentShift = nil }
        setMap([BeatPoint(beat: 0, time: d)], bpm: b)
        autoWarp(rephase: true)
    }

    /// Runs AUTO WARP once per song, as soon as the hits are known.
    func autoWarpIfNeeded() {
        guard let s = song, s.isReady, s.autoWarped != true, !player.hits.isEmpty,
              player.loadedID == s.id else { return }
        // First run on a detected grid: let the hits correct the phase of the 1.
        autoWarp(rephase: s.beatMap == nil || s.beatMap?.count ?? 0 <= 1)
    }

    var pinCount: Int { max(0, points.count - 1) }

    // MARK: View

    func zoom(by factor: Double, around t: Double) {
        let d = duration
        guard d > 0 else { return }
        let minLen = (grid?.beat ?? 0.5) * 2
        let newLen = min(d, max(minLen, viewLength * factor))
        let rel = (t - viewStart) / viewLength
        viewLength = newLen
        viewStart = max(0, min(t - rel * newLen, d - newLen))
    }

    func scroll(by seconds: Double) {
        viewStart = max(0, min(viewStart + seconds, max(0, duration - viewLength)))
    }

    func zoomToFit() {
        viewStart = 0
        viewLength = duration
    }

    /// Page the view along with the playhead.
    func followPlayhead() {
        guard follow, player.isPlaying else { return }
        let p = player.position
        if p < viewStart || p > viewStart + viewLength * 0.92 {
            viewStart = max(0, min(p - viewLength * 0.08, duration - viewLength))
        }
    }

    // MARK: Export

    var exportLanes: [Lane] { lanes.filter { state($0).export } }

    var canExport: Bool {
        loop != nil && !exportLanes.isEmpty && (exportSeparate || exportMix) && !exporting
    }

    /// Every region on screen, each from its own lane, in one go.
    func exportRegions() {
        guard let song, let g = grid, !regions.isEmpty, !exporting else { return }
        let target = outputBPM ?? g.meanBPM
        var base = Exporter.safeName(song.title) + "_" + formatBPM(target) + "bpm"
        if let key = song.key { base += "_" + key }
        var jobs: [ExportJob] = []
        for r in regions.sorted(by: { ($0.laneId, $0.startBar) < ($1.laneId, $1.startBar) }) {
            guard let lane = Lane.all.first(where: { $0.id == r.laneId }) else { continue }
            jobs.append(ExportJob(
                stemsDir: library.stemsDir(song),
                outDir: library.loopsDir.appendingPathComponent(Exporter.safeName(song.title)),
                baseName: base, rangeName: "bar\(r.startBar)-\(r.endBar - 1)",
                start: g.barStart(r.startBar), end: g.barStart(r.endBar),
                outputs: {
                    let st = Dictionary(uniqueKeysWithValues: lane.stems.map { ($0, Float(1)) })
                    return [.init(tag: lane.fileTag, stems: st, parts: [.init(stems: st, segs: segments(for: lane.id))])]
                }(),
                fadeMs: fadeOn ? fadeMs : nil,
                grid: g, beatStart: g.barBeat(r.startBar), beats: Double(r.bars * 4), targetBpm: target,
                sampleRate: song.srcSampleRate, bits: song.srcBits, isFloat: song.srcFloat,
                channels: song.srcChannels, ext: Exporter.outputExt(forSource: song.srcExt)))
        }
        exporting = true
        let all = jobs
        Task.detached(priority: .userInitiated) {
            let result = Result { try all.flatMap { try Exporter.run($0) } }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.exporting = false
                switch result {
                case .success(let urls):
                    self.toast = Toast(text: "\(urls.count) region\(urls.count == 1 ? "" : "s") saved @ \(formatBPM(target)) BPM", files: urls)
                case .failure(let e):
                    self.toast = Toast(text: e.localizedDescription, files: [], isError: true)
                }
            }
        }
    }

    func export() {
        guard let song, let g = grid, let l = loop, let range = loopRange, canExport else { return }
        var outputs: [ExportJob.Output] = []
        if exportSeparate {
            for lane in exportLanes {
                let st = Dictionary(uniqueKeysWithValues: lane.stems.map { ($0, Float(1)) })
                outputs.append(.init(tag: lane.fileTag, stems: st, parts: [.init(stems: st, segs: segments(for: lane.id))]))
            }
        }
        if exportMix {
            // The mix follows the faders, mute and solo of the chosen lanes.
            var stems: [StemKind: Float] = [:]
            var parts: [ExportJob.Part] = []
            for lane in exportLanes where isAudible(lane) {
                var st: [StemKind: Float] = [:]
                for k in lane.stems { stems[k] = state(lane).gain; st[k] = state(lane).gain }
                parts.append(.init(stems: st, segs: segments(for: lane.id)))
            }
            if !stems.isEmpty {
                let tag = exportLanes.count == lanes.count ? "MIX" : "MIX-" + exportLanes.map(\.fileTag).joined(separator: "-")
                outputs.append(.init(tag: tag, stems: stems, parts: parts))
            }
        }
        guard !outputs.isEmpty else { return }

        let target = outputBPM ?? g.meanBPM
        var base = Exporter.safeName(song.title) + "_" + formatBPM(target) + "bpm"
        if let key = song.key { base += "_" + key }
        let rangeName = (l.whole ? "full_" : "") + "bar\(l.startBar)-\(l.endBar - 1)"
        let job = ExportJob(
            stemsDir: library.stemsDir(song),
            outDir: library.loopsDir.appendingPathComponent(Exporter.safeName(song.title)),
            baseName: base, rangeName: rangeName,
            start: range.lowerBound, end: range.upperBound,
            outputs: outputs,
            fadeMs: fadeOn ? fadeMs : nil,
            grid: g, beatStart: g.barBeat(l.startBar), beats: Double(l.bars * 4), targetBpm: target,
            sampleRate: song.srcSampleRate, bits: song.srcBits, isFloat: song.srcFloat,
            channels: song.srcChannels, ext: Exporter.outputExt(forSource: song.srcExt))
        exporting = true
        Task.detached(priority: .userInitiated) {
            let result = Result { try Exporter.run(job) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.exporting = false
                switch result {
                case .success(let urls):
                    self.toast = Toast(text: "\(urls.count) loop\(urls.count == 1 ? "" : "s") saved · \(l.bars) bars @ \(formatBPM(target)) BPM", files: urls)
                case .failure(let e):
                    self.toast = Toast(text: e.localizedDescription, files: [], isError: true)
                }
            }
        }
    }
}
