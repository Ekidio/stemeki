import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let stemekiProject = UTType(exportedAs: "hu.ekidio.stemeki.project", conformingTo: .package)
}

/// State of the open song: lanes, mixer, loop, grid edits, zoom and export.
@MainActor
final class Session: ObservableObject {
    struct LaneState: Codable, Equatable {
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
    @Published var loop: LoopSelection? {
        didSet {
            // Set by hand: the loop no longer follows the pieces / regions it was made from (U).
            if !followingLoop { loopFollows = [] }
            loopChanged()
        }
    }
    /// U: the loop follows these regions / pieces (their start and end) until it is set otherwise.
    @Published private(set) var loopFollows: Set<UUID> = []
    private var followingLoop = false
    /// ⌘C: what was copied (pieces or regions, with their lanes and positions).
    private var clipboardClips: [Clip] = []
    private var clipboardRegions: [Region] = []
    private var clipboardIsEdit = true
    /// ⌘V goes here (ticks): set by a click on an empty spot of a lane. nil = the playhead.
    @Published var pasteAt: Int?
    @Published var loopEnabled = true { didSet { loopChanged() } }
    /// NUDGE step in beats (½ beat, 1 beat, ½ bar, 1 bar).
    @Published var nudgeStep: Double = 0.5 { didSet { UserDefaults.standard.set(nudgeStep, forKey: "nudgeStep") } }
    @Published var follow = true
    @Published var selected: Set<UUID> = []

    /// EDIT: drag marks a range to cut; EXPORT: drag marks regions to export.
    enum WorkMode: String { case edit, export }
    @Published var workMode: WorkMode = .edit { didSet { selected = []; cueGhost = nil } }
    /// Edit selections (ranges to cut). Not saved and never exported.
    @Published var marks: [Region] = [] { didSet { followLoop() } }

    private var activeRegionList: [Region] { workMode == .edit ? marks : allRegions }
    private func storeActive(_ l: [Region]) { if workMode == .edit { marks = l } else { storeRegions(l) } }
    /// Where the CUE flag is being dragged to (time), drawn as a ghost until released.
    @Published var cueGhost: Double?
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    private struct Snapshot {
        var regions: [Region]
        var clips: [Clip]?
        var beatMap: [BeatPoint]?
        var bpm: Double?
        var downbeat: Double?
        var loop: LoopSelection?
        var marks: [Region] = []
    }

    private var snapshot: Snapshot {
        Snapshot(regions: allRegions, clips: song?.clips, beatMap: song?.beatMap, bpm: song?.bpm,
                 downbeat: song?.downbeat, loop: loop, marks: marks)
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
        // SELECTED MIX has no button any more: every lane always exports to its own file.
        selectedMix = false
        nudgeStep = d.object(forKey: "nudgeStep") as? Double ?? 0.5
        // Fade is off on every launch, on purpose.
        fadeOn = false
        Session.current = self
    }

    var song: Song? { library.selected }
    var grid: Grid? { song?.grid }
    var lanes: [Lane] { Lane.lanes(for: mode) }
    /// The timeline: the song, or longer when pieces were moved past its end.
    var duration: Double { player.length > 0 ? player.length : (song?.duration ?? 0) }
    /// The song itself (FULL export).
    var songDuration: Double { player.duration > 0 ? player.duration : (song?.duration ?? 0) }

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
        // An opened project brings back its lane levels, mutes and export marks.
        if let m = library.takeMixer(song.id) { laneStates = m }
        marks = []
        pasteAt = nil
        workMode = .edit
        // Every song starts as one waveform (MIX); stems come in when asked for.
        mode = song.viewMode ?? .mix
        if let start = song.loopStartTick, let len = song.loopLenTick {
            loop = LoopSelection(start: start, len: len, whole: song.loopWhole ?? false)
        } else if let start = song.loopStartBar, let bars = song.loopBars {
            loop = LoopSelection(startBar: start, bars: bars, whole: song.loopWhole ?? false)
        } else {
            loop = nil
        }
        let d = duration
        if let g = song.grid {
            // About 16 bars on screen, with clear space before the CUE.
            viewLength = min(d, g.bar * 16)
            viewStart = clampView(g.anchor - g.bar)
        } else {
            viewLength = min(d, 30)
            viewStart = 0
        }
        applyGains()
        syncPlayer()
        resumeHandOff()
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
        return g.tickTime(loop.start)...g.tickTime(loop.end)
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
            s.loopStartTick = l?.start
            s.loopLenTick = l?.len
        }
    }

    func clampLoop(_ l: LoopSelection) -> LoopSelection? {
        guard let g = grid, g.fullBars > 0 else { return nil }
        let lo = g.fullStartT, hi = timelineEndT
        var l = l
        l.len = max(1, min(l.len, hi - lo))
        l.start = max(lo, min(l.start, hi - l.len))
        return l
    }

    /// End of the timeline in ticks: the last full bar, or the end of a piece moved past it.
    var timelineEndT: Int {
        guard let g = grid else { return 0 }
        return max(g.fullEndT, allClips.map(\.end).max() ?? 0)
    }

    func setLoopLength(_ bars: Int) {
        guard let g = grid else { return }
        let start = loop.map { $0.whole ? g.barIndex(at: player.position) : $0.startBar } ?? g.barIndex(at: player.position)
        loop = clampLoop(LoopSelection(startBar: start, bars: bars))
        loopEnabled = true
        if !player.isPlaying, let r = loopRange { player.seek(max(0, r.lowerBound)) }
    }

    func setWholeSong() {
        guard let g = grid, g.fullBars > 0 else { return }
        loop = LoopSelection(startBar: g.firstFullBar, bars: g.fullBars, whole: true)
        loopEnabled = true
    }

    func shiftLoop(_ dir: Int) {
        guard let l = loop, !l.whole else { return }
        if let n = clampLoop(LoopSelection(start: l.start + dir * l.len, len: l.len)) {
            loop = n
            if let r = loopRange { player.seek(max(0, r.lowerBound)) }
        }
        revealLoop()
    }

    func halveLoop() { if let l = loop, l.len > 1, !l.whole { loop = clampLoop(LoopSelection(start: l.start, len: l.len / 2)) } }
    func doubleLoop() { if let l = loop, !l.whole { loop = clampLoop(LoopSelection(start: l.start, len: l.len * 2)) } }

    /// U: the loop takes the start and end of the selection (regions, edit selections or pieces) and follows them.
    func loopToSelection() {
        let ids = selected
        guard let span = span(of: ids) else { return }
        let before = loopRange
        followingLoop = true
        loop = clampLoop(LoopSelection(start: span.0, len: span.1 - span.0))
        followingLoop = false
        loopFollows = ids
        loopEnabled = true
        if let r = loopRange { Celebrate.shared.loop(from: before, to: r) }
        if let r = loopRange, !player.isPlaying || !r.contains(player.position) { player.seek(max(0, r.lowerBound)) }
    }

    /// Start and end (ticks) of these regions / edit selections / pieces together.
    private func span(of ids: Set<UUID>) -> (Int, Int)? {
        let rs = (allRegions + marks).filter { ids.contains($0.id) }
        let cs = allClips.filter { ids.contains($0.id) }
        let starts = rs.map(\.start) + cs.map(\.start), ends = rs.map(\.end) + cs.map(\.end)
        guard let lo = starts.min(), let hi = ends.max(), hi > lo else { return nil }
        return (lo, hi)
    }

    /// Keeps a followed loop on its regions / pieces after they were moved, trimmed or cut.
    private func followLoop() {
        guard !loopFollows.isEmpty else { return }
        guard let s = span(of: loopFollows), let n = clampLoop(LoopSelection(start: s.0, len: s.1 - s.0)) else {
            loopFollows = []
            return
        }
        guard n != loop else { return }
        followingLoop = true
        loop = n
        followingLoop = false
    }

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
            viewStart = clampView(r.lowerBound - (viewLength - len) / 2)
        }
    }

    // MARK: Edits

    private var allRegions: [Region] { song?.regions ?? [] }
    private var allClips: [Clip] { song?.clips ?? [] }

    private func storeRegions(_ list: [Region]) {
        guard let id = song?.id else { return }
        library.update(id) { $0.regions = list }
        followLoop()
    }

    private func storeClips(_ list: [Clip]) {
        guard let id = song?.id else { return }
        library.update(id) { $0.clips = list.isEmpty ? nil : list }
        syncArrangement()
        followLoop()
    }

    /// Call before a change the user may want to undo.
    func checkpoint() {
        undoStack.append(snapshot)
        if undoStack.count > 60 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func restore(_ s: Snapshot) {
        guard let id = song?.id else { return }
        library.update(id) {
            $0.regions = s.regions; $0.clips = s.clips
            $0.beatMap = s.beatMap; $0.bpm = s.bpm; $0.downbeat = s.downbeat
        }
        marks = s.marks
        if loop != s.loop { loop = s.loop } else { loopChanged() }
        syncArrangement()
        let ids = Set(s.regions.map(\.id) + (s.clips ?? []).map(\.id))
        selected = selected.filter { ids.contains($0) }
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        restore(last)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot)
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
        // From the pickup bar before bar 1 to past the last full bar.
        return list + [Clip(laneId: laneId, start: g.fullStartT - ticksPerBar, src: g.fullStartT - ticksPerBar,
                            len: g.fullEndT - g.fullStartT + 2 * ticksPerBar)]
    }

    /// Clicking inside a region: cut the lane's audio at its start and end. The piece between is selected.
    func cutAtRegion(_ rid: UUID) {
        guard let r = activeRegionList.first(where: { $0.id == rid }) else { return }
        checkpoint()
        var list = clipsWithLane(r.laneId, allClips)
        var inside: [UUID] = []
        var out: [Clip] = []
        for c in list {
            guard c.laneId == r.laneId, c.start < r.end, c.end > r.start else { out.append(c); continue }
            let cuts = [c.start, max(c.start, r.start), min(c.end, r.end), c.end]
            var first = true
            for k in 0..<3 where cuts[k + 1] > cuts[k] {
                var p = c
                if !first { p.id = UUID() }
                first = false
                p.src = c.src + (cuts[k] - c.start)
                p.start = cuts[k]
                p.len = cuts[k + 1] - cuts[k]
                // Each piece keeps only the fades of the outer edges it still has.
                if cuts[k] > c.start { p.fadeIn = 0 }
                if cuts[k + 1] < c.end { p.fadeOut = 0 }
                p.clampFades()
                out.append(p)
                if k == 1 { inside.append(p.id) }
            }
        }
        list = out
        // A loop that followed this selection now follows the piece cut from it.
        if loopFollows.contains(rid) { loopFollows.remove(rid); loopFollows.formUnion(inside) }
        storeClips(list)
        storeActive(activeRegionList.filter { $0.id != rid })
        selected = Set(inside)
    }

    /// How far past the song pieces may go (ticks): room for a longer mix.
    private var maxEndT: Int { (grid?.fullEndT ?? 0) + 512 * ticksPerBar }

    /// Moves clips from their `base` state by whole ticks (same lane). Past the end of the song is fine:
    /// the timeline grows with them.
    func moveClips(_ base: [Clip], ticks: Int) {
        guard let g = grid else { return }
        var list = allClips
        for c in base {
            guard let i = list.firstIndex(where: { $0.id == c.id }) else { continue }
            list[i].start = max(g.fullStartT - ticksPerBar, min(c.start + ticks, maxEndT - c.len))
        }
        if list != allClips { storeClips(list) }
    }

    /// ⌘-drag: the pieces follow the mouse freely, to the sample. Each frame lands on the nearest sixteenth and
    /// the rest goes into the audio's slide inside it, so the sound is exactly `seconds` away from where it was.
    func moveClipsFree(_ base: [Clip], seconds dt: Double) {
        guard let g = grid else { return }
        let sr = player.stemRate
        var list = allClips
        for c in base {
            guard let i = list.firstIndex(where: { $0.id == c.id }) else { continue }
            let k = Int(g.tick(at: g.tickTime(c.start) + dt).rounded())
            let s = max(g.fullStartT - ticksPerBar, min(k, maxEndT - c.len))
            list[i].start = s
            list[i].slip = ((c.slip + dt - (g.tickTime(s) - g.tickTime(c.start))) * sr).rounded() / sr
        }
        if list != allClips { storeClips(list) }
    }

    // MARK: Regions

    /// Regions of the lanes on screen (2-stem and 4-stem have different lanes).
    var regions: [Region] {
        let ids = Set(lanes.map(\.id))
        return activeRegionList.filter { ids.contains($0.laneId) }
    }

    /// Export regions of the lanes on screen (whatever the mode).
    var exportRegionList: [Region] {
        let ids = Set(lanes.map(\.id))
        return allRegions.filter { ids.contains($0.laneId) }
    }

    /// Keeps a tick range from bar 1 of the song to the end of the timeline (pieces may lie past the song).
    private func clampSpan(_ start: Int, _ len: Int) -> (Int, Int)? {
        guard let g = grid, g.fullBars > 0 else { return nil }
        let hi = max(timelineEndT, g.fullEndT)
        let n = max(1, min(len, hi - g.fullStartT))
        return (max(g.fullStartT, min(start, hi - n)), n)
    }

    @discardableResult
    func addRegion(lane: Lane, start: Int, len: Int) -> UUID {
        let r = Region(laneId: lane.id, start: start, len: max(1, len))
        guard let (s, n) = clampSpan(r.start, r.len) else { return r.id }
        var nr = r
        nr.start = s; nr.len = n
        checkpoint()
        storeActive(activeRegionList + [nr])
        selected = [nr.id]
        return nr.id
    }

    func setRegion(_ rid: UUID, start: Int, len: Int) {
        guard let (s, n) = clampSpan(start, len) else { return }
        var list = activeRegionList
        guard let i = list.firstIndex(where: { $0.id == rid }), list[i].start != s || list[i].len != n else { return }
        list[i].start = s
        list[i].len = n
        storeActive(list)
    }

    /// Moves regions from their `base` state by whole ticks and lanes (lane index within the lanes on screen).
    /// EDIT: the selected pieces whose audio slides sample by sample (← →).
    var slidableClips: [Clip] { workMode == .edit ? allClips.filter { selected.contains($0.id) } : [] }

    private var lastSlide = Date.distantPast

    /// Slides the audio inside the selected pieces by whole samples (of the stems), off the grid; the pieces
    /// stay where they are. A run of presses is one undo step.
    func slideSelectedClips(samples: Int) {
        guard !slidableClips.isEmpty else { return }
        if Date().timeIntervalSince(lastSlide) > 1.5 { checkpoint() }
        lastSlide = Date()
        let sr = player.stemRate
        storeClips(allClips.map { c in
            guard selected.contains(c.id) else { return c }
            var c = c
            c.slip = (c.slip * sr + Double(samples)).rounded() / sr
            return c
        })
    }

    func resetClipSlips() {
        guard slidableClips.contains(where: { $0.slip != 0 }) else { return }
        checkpoint()
        storeClips(allClips.map { c in var c = c; if selected.contains(c.id) { c.slip = 0 }; return c })
    }

    /// The slide of the selected pieces in samples (nil: several different).
    var slideSamples: Int? {
        let set = Set(slidableClips.map { Int(($0.slip * player.stemRate).rounded()) })
        return set.count == 1 ? set.first : nil
    }

    func moveRegions(_ base: [Region], ticks: Int, lanes laneDelta: Int) {
        let ls = lanes
        var list = activeRegionList
        for r in base {
            guard let i = list.firstIndex(where: { $0.id == r.id }) else { continue }
            if let (s, n) = clampSpan(r.start + ticks, r.len) { list[i].start = s; list[i].len = n }
            if let li = ls.firstIndex(where: { $0.id == r.laneId }) {
                list[i].laneId = ls[max(0, min(ls.count - 1, li + laneDelta))].id
            }
        }
        if list != activeRegionList { storeActive(list) }
    }

    func deleteRegion(_ rid: UUID) {
        checkpoint()
        storeActive(activeRegionList.filter { $0.id != rid })
        selected.remove(rid)
    }

    /// Delete: selected clips go silent, selected regions disappear.
    func deleteSelected() {
        guard !selected.isEmpty else { return }
        checkpoint()
        let sel = selected
        if allClips.contains(where: { sel.contains($0.id) }) { storeClips(allClips.filter { !sel.contains($0.id) }) }
        storeActive(activeRegionList.filter { !sel.contains($0.id) })
        selected = []
    }

    /// Copies of the selected clips/regions; `place` = right after the selection (⌘D), else on top (⌥-drag).
    @discardableResult
    func duplicateSelected(place: Bool = true) -> (clips: [Clip], regions: [Region]) {
        let selC = clips.filter { selected.contains($0.id) }
        let selR = regions.filter { selected.contains($0.id) }
        guard !selC.isEmpty || !selR.isEmpty else { return ([], []) }
        let lo = (selC.map(\.start) + selR.map(\.start)).min()!
        let hi = (selC.map(\.end) + selR.map(\.end)).max()!
        let shift = place ? hi - lo : 0
        checkpoint()
        let newC = selC.map { c -> Clip in var n = c; n.id = UUID(); n.start += shift; return n }
        let newR = selR.map { r -> Region in
            var n = r; n.id = UUID()
            if let (s, b) = clampSpan(r.start + shift, r.len) { n.start = s; n.len = b }
            return n
        }
        if !newC.isEmpty {
            storeClips(allClips + newC)
            // Placed right after: overwrite what was there (⌥-drag resolves when it is dropped).
            if place { resolveOverlaps(Set(newC.map(\.id))) }
        }
        if !newR.isEmpty { storeActive(activeRegionList + newR) }
        selected = Set(newC.map(\.id) + newR.map(\.id))
        return (newC, newR)
    }

    /// Trims a piece from its `base` state: a new start (earlier = reveals more audio before it) and/or a new end.
    func trimClip(_ base: Clip, start: Int? = nil, end: Int? = nil) {
        guard let g = grid else { return }
        var list = allClips
        guard let i = list.firstIndex(where: { $0.id == base.id }) else { return }
        var c = base
        let songLo = g.fullStartT - ticksPerBar, songHi = g.fullEndT + ticksPerBar
        if let s = start {
            var ns = min(s, base.end - 1)
            ns = max(ns, base.start - (base.src - songLo))      // cannot reveal audio before the song
            c.src = base.src + (ns - base.start)
            c.start = ns
            c.len = base.end - ns
        }
        if let e = end {
            var ne = max(e, c.start + 1)
            ne = min(ne, c.start + (songHi - c.src))            // nor after it
            c.len = ne - c.start
        }
        c.clampFades()
        guard list[i] != c else { return }
        list[i] = c
        storeClips(list)
    }

    /// A piece's fade-in / fade-out (beats), from its `base` state; nil leaves that side alone.
    func setFades(_ base: Clip, fadeIn: Double? = nil, fadeOut: Double? = nil) {
        var list = allClips
        guard let i = list.firstIndex(where: { $0.id == base.id }) else { return }
        var c = list[i]
        if let f = fadeIn { c.fadeIn = f }
        if let f = fadeOut { c.fadeOut = f }
        // The side being dragged gives way to the other one.
        let l = Double(c.len) / Double(ticksPerBeat)
        if fadeIn != nil { c.fadeIn = max(0, min(c.fadeIn, l - c.fadeOut)) } else { c.fadeOut = max(0, min(c.fadeOut, l - c.fadeIn)) }
        guard list[i] != c else { return }
        list[i] = c
        storeClips(list)
    }

    /// Overwrite: the pieces in `ids` cut away whatever they cover on their lanes (other pieces lose
    /// the overlapping part; the rest of them stays).
    func resolveOverlaps(_ ids: Set<UUID>) {
        let out = allClips.overwritten(by: ids)
        if out != allClips { storeClips(out) }
    }

    // MARK: Copy and paste

    /// The audio a lane plays in [start, end) as pieces (an unedited lane plays the song as it is).
    private func pieces(lane laneId: String, _ start: Int, _ end: Int) -> [Clip] {
        let segs = segments(for: laneId) ?? [Seg(tl: start, src: start, len: end - start)]
        return segs.compactMap { s in
            let a = max(s.tl, start), b = min(s.tl + s.len, end)
            guard b > a else { return nil }
            var c = Clip(laneId: laneId, start: a, src: s.src + (a - s.tl), len: b - a)
            c.slip = s.slip
            return c
        }
    }

    /// ⌘C: EDIT copies the selected pieces (or the audio under the selected edit selections),
    /// EXPORT copies the selected regions.
    func copySelection() {
        if workMode == .edit {
            var list = clips.filter { selected.contains($0.id) }
            for m in marks where selected.contains(m.id) { list += pieces(lane: m.laneId, m.start, m.end) }
            guard !list.isEmpty else { return }
            clipboardClips = list
            clipboardIsEdit = true
            toast = Toast(text: "Copied · click where it goes, then ⌘V", files: [])
        } else {
            let list = regions.filter { selected.contains($0.id) }
            guard !list.isEmpty else { return }
            clipboardRegions = list
            clipboardIsEdit = false
            toast = Toast(text: "\(list.count) region\(list.count == 1 ? "" : "s") copied · click where it goes, then ⌘V", files: [])
        }
    }

    var canPaste: Bool { workMode == .edit ? !clipboardClips.isEmpty : !clipboardRegions.isEmpty }

    /// ⌘V: the copy goes to the paste point (or the beat at the playhead), on the lanes it came from,
    /// overwriting what is there. The paste point moves to its end, so ⌘V again lines up the next copy.
    func paste() {
        guard let g = grid, canPaste else { return }
        let ids = Set(lanes.map(\.id))
        let at = pasteAt ?? Int((g.tick(at: player.position) / Double(ticksPerBeat)).rounded()) * ticksPerBeat
        if workMode == .edit {
            let src = clipboardClips.filter { ids.contains($0.laneId) }
            guard let lo = src.map(\.start).min(), let hi = src.map(\.end).max() else {
                toast = Toast(text: "The copied lanes are not on screen", files: [], isError: true)
                return
            }
            let shift = at - lo
            checkpoint()
            var list = allClips
            for laneId in Set(src.map(\.laneId)) { list = clipsWithLane(laneId, list) }
            let new = src.map { c -> Clip in
                var n = c; n.id = UUID(); n.start = min(c.start + shift, maxEndT - c.len); return n
            }
            storeClips(list + new)
            resolveOverlaps(Set(new.map(\.id)))
            selected = Set(new.map(\.id))
            pasteAt = at + (hi - lo)
        } else {
            let src = clipboardRegions.filter { ids.contains($0.laneId) }
            guard let lo = src.map(\.start).min(), let hi = src.map(\.end).max() else { return }
            checkpoint()
            let new = src.compactMap { r -> Region? in
                guard let (s, n) = clampSpan(r.start + at - lo, r.len) else { return nil }
                var nr = r; nr.id = UUID(); nr.start = s; nr.len = n; return nr
            }
            storeActive(activeRegionList + new)
            selected = Set(new.map(\.id))
            pasteAt = at + (hi - lo)
        }
    }

    /// D: duplicate what is selected. In EDIT an uncut selection is cut first, then its piece is copied.
    func quickDuplicate() {
        if workMode == .edit {
            let uncut = marks.filter { selected.contains($0.id) }.map(\.id)
            var pieces = Set<UUID>()
            for id in uncut {
                cutAtRegion(id)
                pieces.formUnion(selected)
            }
            if !uncut.isEmpty { selected = pieces.union(selected.filter { id in allClips.contains { $0.id == id } }) }
        }
        duplicateSelected()
    }

    /// The lane back to how it came out of the separation: no edits, default level, unmuted, exported.
    func resetLane(_ lane: Lane) {
        let hasEdits = allClips.contains { $0.laneId == lane.id } || marks.contains { $0.laneId == lane.id }
        if hasEdits {
            checkpoint()
            marks.removeAll { $0.laneId == lane.id }
            storeClips(allClips.filter { $0.laneId != lane.id })
        }
        setState(lane) { $0 = LaneState() }
        selected = selected.filter { id in allClips.contains { $0.id == id } || allRegions.contains { $0.id == id } }
    }

    func laneIsPristine(_ lane: Lane) -> Bool {
        let st = state(lane)
        return !allClips.contains { $0.laneId == lane.id } && !marks.contains { $0.laneId == lane.id }
            && st.gain == 1 && !st.mute && !st.solo && st.export
    }

    /// Esc: nothing selected, no edit selection left on the lanes.
    func clearSelection() {
        selected = []
        marks = []
        cueGhost = nil
        pasteAt = nil
    }

    func selectAll() { selected = Set(regions.map(\.id) + clips.filter { _ in true }.map(\.id)) }

    func clearRegions() {
        let ids = Set(regions.map(\.id))
        guard !ids.isEmpty else { return }
        checkpoint()
        storeActive(activeRegionList.filter { !ids.contains($0.id) })
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

    /// The grid from the beat model: straight lines where the song keeps one tempo, numbered from the model's
    /// first downbeat (bar 1). nil without model beats, or before the hits are known.
    private func modelMap() -> [BeatPoint]? {
        guard let b = song?.modelBeats, let d = song?.modelDownbeats, !player.hits.isEmpty else { return nil }
        return SmartTempo.map(beats: b, downbeats: d, hits: player.hits)
    }

    /// AUTO WARP: the grid from the beat model (or, without it, follow the drum hits from the 1).
    /// `rephase`: the model's own 1; otherwise the 1 that is set now stays exactly where it is.
    func autoWarp(rephase: Bool = false) {
        guard let g = grid, !player.hits.isEmpty else { return }
        if let pts = modelMap() {
            if rephase {
                setMap(pts)
            } else {
                let k = Grid(points: pts, bpm: g.bpm, duration: g.duration).beat(at: g.anchor)
                setMap(pts.map { BeatPoint(beat: $0.beat - k, time: $0.time) })
            }
            if let id = song?.id { library.update(id) { $0.autoWarped = true } }
            return
        }
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
        if let pts = modelMap() {
            checkpoint()
            setMap(pts)
            return
        }
        setMap([BeatPoint(beat: 0, time: d)], bpm: b)
        autoWarp(rephase: true)
        autoCue(undoable: false)
    }

    /// Runs AUTO WARP once per song, as soon as the hits are known, then puts the CUE on the first warp marker.
    func autoWarpIfNeeded() {
        guard let s = song, s.isReady, !player.hits.isEmpty, player.loadedID == s.id else { return }
        if s.autoWarped != true {
            // First run on a detected grid: let the hits correct the phase of the 1.
            autoWarp(rephase: s.beatMap == nil || s.beatMap?.count ?? 0 <= 1)
        }
        if song?.autoCued != true {
            autoCue(undoable: false)
            if let id = song?.id { library.update(id) { $0.autoCued = true } }
        }
        // Re-analyzed: the edits were counted from the old bar 1; keep them on the same music.
        if let t0 = song?.recueFrom, let g = grid, let id = song?.id {
            library.update(id) { $0.recueFrom = nil }
            shiftEdits(by: Int((g.beat(at: t0) * Double(ticksPerBeat)).rounded()))
        }
    }

    // MARK: CUE (bar 1)

    /// The first drum hit at full strength (at least half as strong as the song's main kicks).
    func firstFullDrumHit() -> Double? {
        guard let d = player.hits[.drums], d.times.count > 8 else { return nil }
        let w = d.weights.sorted()
        let main = w[Int(Double(w.count - 1) * 0.9)]
        guard let i = d.weights.firstIndex(where: { $0 >= main * 0.5 }) else { return nil }
        return d.times[i]
    }

    /// CUE HERE: the 1 goes exactly to the drum hit at the playhead (or the playhead itself), also between the
    /// grid's beats. The warp map stays as it is (it follows the tempo); only its numbering moves, so the bars,
    /// the click and the loops start where you hear the 1.
    func cueToPlayhead() {
        guard let g = grid else { return }
        let t = nearestHit(to: player.position, stems: [.drums], maxDist: g.beat * 0.2) ?? player.position
        let k = g.beat(at: t)
        moveCue(toBeat: abs(k - k.rounded()) < 0.02 ? k.rounded() : k)
    }

    /// The first real drum hit (at least a quarter of the main kicks' strength) that falls on a beat of the grid,
    /// so a faint tick in a quiet intro does not become the 1.
    private func firstDrumMarker(_ g: Grid) -> BeatPoint? {
        guard let d = player.hits[.drums], d.times.count > 8 else { return g.points.min { $0.beat < $1.beat } }
        let w = d.weights.sorted()
        let main = w[Int(Double(w.count - 1) * 0.9)]
        for (t, wt) in zip(d.times, d.weights) where wt >= main * 0.25 {
            let b = g.beat(at: t)
            if abs(b - b.rounded()) < 0.06 { return BeatPoint(beat: b.rounded(), time: g.time(b.rounded())) }
        }
        return g.points.min { $0.beat < $1.beat }
    }

    /// CUE on the first warp marker that sits on a real drum hit. Only the numbering moves: the warp map
    /// stays the one tracked from the song's strong part (tracking again from a sparse intro could drift).
    /// Without markers: the beat line nearest to the first full drum hit.
    func autoCue(undoable: Bool = true) {
        guard let g = grid else { return }
        // The beat model's first downbeat is the 1 (the grid is already numbered from it after AUTO WARP).
        if song?.modelBeats != nil, let d = song?.modelDownbeats?.first {
            let k = g.beat(at: d).rounded()
            if abs(k) > 1e-9 { moveCue(toBeat: k, undoable: undoable) }
            return
        }
        if !player.hits.isEmpty, let first = firstDrumMarker(g) {
            if abs(first.beat) > 1e-9 { moveCue(toBeat: first.beat, undoable: undoable) }
            return
        }
        guard let t = firstFullDrumHit() else { return }
        moveCue(toBeat: g.beat(at: t).rounded(), undoable: undoable)
    }

    /// Makes beat `k` (in the current numbering, may be fractional) the CUE = bar 1. Only the numbering
    /// changes: the grid stays on the music, and regions, cuts and the loop stay where they are in the song.
    func moveCue(toBeat k: Double, undoable: Bool = true) {
        guard let g = grid, abs(k) > 1e-9 else { return }
        if undoable { checkpoint() }
        setMap(g.points.map { BeatPoint(beat: $0.beat - k, time: $0.time) })
        // Edits move with the music (to the nearest sixteenth when the 1 moved between the lines).
        shiftEdits(by: -Int((k * Double(ticksPerBeat)).rounded()))
    }

    /// Moves regions, cuts, marks and the loop by `d` ticks in the numbering (they stay on the same music
    /// when the 1 moves the other way).
    private func shiftEdits(by d: Int) {
        if d != 0 {
            if !allRegions.isEmpty { storeRegions(allRegions.map { var r = $0; r.start += d; return r }) }
            marks = marks.map { var r = $0; r.start += d; return r }
            if !allClips.isEmpty { storeClips(allClips.map { var c = $0; c.start += d; c.src += d; return c }) }
            if let p = pasteAt { pasteAt = p + d }
        }
        if var l = loop {
            // The loop stays on the same music.
            l.start += d
            followingLoop = !loopFollows.isEmpty
            loop = l
            followingLoop = false
        }
    }

    var pinCount: Int { max(0, points.count - 1) }

    // MARK: View

    func zoom(by factor: Double, around t: Double) {
        let d = duration
        guard d > 0 else { return }
        // Close enough to see the sixteenths (one beat across the timeline).
        let minLen = grid?.beat ?? 0.5
        let newLen = min(d + preRoll + postRoll, max(minLen, viewLength * factor))
        let rel = (t - viewStart) / viewLength
        viewLength = newLen
        viewStart = clampView(t - rel * newLen)
    }

    func scroll(by seconds: Double) {
        viewStart = clampView(viewStart + seconds)
    }

    private var handOffTo: (id: UUID, preview: SourcePreview)?

    /// The processing screen was playing the song: it keeps playing until the stems take over in the editor,
    /// at the same moment of the song.
    func handOff(songID: UUID, from preview: SourcePreview) {
        handOffTo?.preview.stop()
        handOffTo = (songID, preview)
        if player.loadedID == songID { resumeHandOff() }
    }

    private func resumeHandOff() {
        guard let h = handOffTo, player.loadedID == h.id else { return }
        handOffTo = nil
        // The stems start ~50 ms from now (sample-locked start): pick up the song where the preview will be then,
        // and let the preview fade out at that very moment.
        let lead = 0.05
        player.warmUp()
        let t = h.preview.currentTime + lead
        player.seek(t)
        player.play()
        h.preview.handOver(after: lead)
        // Coming from the preparing screen: follow the playhead, starting where the music is.
        follow = true
        viewStart = clampView(t - viewLength * 0.08)
    }

    /// Playhead to the very start; with FOLLOW the view goes there too.
    func goToStart() {
        player.seek(0)
        if follow { viewStart = clampView(min(0, (grid?.anchor ?? 0) - (grid?.bar ?? 2))) }
    }

    /// Empty space allowed before the song starts (one bar: bar 0), so the start is never squeezed.
    var preRoll: Double { grid?.bar ?? 2 }

    /// Empty space after the end, so pieces can be dragged past the song (a longer mix).
    var postRoll: Double { (grid?.bar ?? 2) * 8 }

    func clampView(_ s: Double) -> Double {
        max(-preRoll, min(s, max(-preRoll, duration - viewLength + postRoll)))
    }

    func zoomToFit() {
        viewStart = -preRoll * 0.5
        viewLength = duration + preRoll
    }

    /// Page the view along with the playhead.
    func followPlayhead() {
        guard follow, player.isPlaying else { return }
        let p = player.position
        if p < viewStart || p > viewStart + viewLength * 0.92 {
            viewStart = clampView(p - viewLength * 0.08)
        }
    }

    // MARK: Projects

    private var projectsFolder: URL {
        if let p = UserDefaults.standard.string(forKey: "projectsFolder"), FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        let d = library.root.appendingPathComponent("Projects")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// ⌘S: saves the song to its project (asks where the first time); ⇧⌘S always asks.
    /// Returns false when the user cancelled.
    @discardableResult
    func saveProject(_ id: UUID? = nil, saveAs: Bool = false) -> Bool {
        guard let song = library.songs.first(where: { $0.id == (id ?? self.song?.id) }), song.isReady else { return true }
        var url = song.projectPath.map { URL(fileURLWithPath: $0) }
        if saveAs || url == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.stemekiProject]
            panel.nameFieldStringValue = song.title + "." + Library.projectExtension
            panel.directoryURL = url?.deletingLastPathComponent() ?? projectsFolder
            panel.canCreateDirectories = true
            panel.message = "Save “\(song.title)” with its stems and edits"
            panel.prompt = "Save"
            guard panel.runModal() == .OK, let u = panel.url else { return false }
            url = u
            UserDefaults.standard.set(u.deletingLastPathComponent().path, forKey: "projectsFolder")
        }
        guard let url else { return false }
        do {
            try library.saveProject(song.id, mixer: laneStates, to: url)
            toast = Toast(text: "Saved · \(url.lastPathComponent)", files: [url])
            return true
        } catch {
            projectAlert("Could not save “\(url.lastPathComponent)”", error)
            return false
        }
    }

    /// ⇧⌘O
    func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.stemekiProject]
        panel.allowsMultipleSelection = true
        panel.directoryURL = projectsFolder
        panel.message = "Open STEMEKI projects"
        guard panel.runModal() == .OK else { return }
        library.add(panel.urls)
    }

    // MARK: Export

    var exportLanes: [Lane] { lanes.filter { state($0).export } }

    /// The four exports, from the plain to the unique.
    enum ExportKind { case full, cue, loop, regions }

    /// SELECTED MIX: the marked lanes go into one file instead of one file per lane.
    @Published var selectedMix = false { didSet { UserDefaults.standard.set(selectedMix, forKey: "selectedMix") } }

    /// Export regions on lanes marked for export.
    var regionsToExport: [Region] {
        let ids = Set(exportLanes.map(\.id))
        return exportRegionList.filter { ids.contains($0.laneId) }
    }

    func canExport(_ kind: ExportKind) -> Bool {
        guard !exporting, grid != nil, !exportLanes.isEmpty else { return false }
        switch kind {
        case .full, .cue: return true
        case .loop: return loop != nil && loopEnabled
        case .regions: return !regionsToExport.isEmpty
        }
    }

    /// MIDI root note of the song's key (for the ACID data).
    private var rootNote: Int? {
        guard let key = song?.key else { return nil }
        let names = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
        let root = key.hasSuffix("m") ? String(key.dropLast()) : key
        return names.firstIndex(of: root).map { 60 + $0 }
    }

    func export(_ kind: ExportKind) {
        guard let song, let g = grid, canExport(kind) else { return }
        let target = outputBPM ?? g.meanBPM
        let title = Exporter.safeName(song.title)
        let bpm = formatBPM(target) + "bpm"
        let lanesOut = exportLanes

        // What gets written: one file per lane, or the marked lanes mixed (following their faders).
        func outputs(name: (String) -> String, edited: Bool) -> [ExportJob.Output] {
            func part(_ lane: Lane, _ gain: Float) -> ExportJob.Part {
                .init(stems: Dictionary(uniqueKeysWithValues: lane.stems.map { ($0, gain) }),
                      segs: edited ? segments(for: lane.id) : nil)
            }
            if selectedMix && kind != .regions {
                let tag = lanesOut.map(\.fileTag).joined(separator: "+")
                var stems: [StemKind: Float] = [:]
                for lane in lanesOut { for k in lane.stems { stems[k] = state(lane).gain } }
                return [.init(tag: tag, stems: stems, parts: lanesOut.map { part($0, state($0).gain) }, name: name(tag))]
            }
            return lanesOut.map { lane in
                let p = part(lane, 1)
                return .init(tag: lane.fileTag, stems: p.stems, parts: [p], name: name(lane.fileTag))
            }
        }

        func job(_ outs: [ExportJob.Output], beatStart: Double, beats: Double, stretch: Bool, acid: ExportJob.Acid?,
                 folder: URL) -> ExportJob {
            ExportJob(stemsDir: library.stemsDir(song), outDir: folder, baseName: title, rangeName: "",
                      start: g.time(beatStart), end: g.time(beatStart + beats), outputs: outs,
                      fadeMs: fadeOn ? fadeMs : nil, grid: g, beatStart: beatStart, beats: beats,
                      targetBpm: stretch ? target : g.meanBPM, stretch: stretch, acid: acid,
                      sampleRate: song.srcSampleRate, bits: song.srcBits, isFloat: song.srcFloat,
                      channels: song.srcChannels, ext: Exporter.outputExt(forSource: song.srcExt))
        }

        let what: String
        switch kind {
        case .full: what = "the full stems"
        case .cue: what = "the stems from the CUE"
        case .loop: what = "the loop stems"
        case .regions: what = "\(regionsToExport.count) region\(regionsToExport.count == 1 ? "" : "s")"
        }
        guard let folder = library.chooseExportFolder(title: "Where should \(what) of “\(song.title)” go?") else { return }

        var jobs: [ExportJob] = []
        var summary = ""
        switch kind {
        case .full:
            // As it is: the whole file, original tempo, no edits.
            let b0 = g.beat(at: 0), b1 = g.beat(at: songDuration)
            jobs = [job(outputs(name: { "\(title)_\($0)_FULL" }, edited: false),
                        beatStart: b0, beats: b1 - b0, stretch: false, acid: nil, folder: folder)]
            summary = "full stems"
        case .cue:
            // From bar 1 to the very end (pieces moved past the song included), on the export tempo,
            // so stems line up from the CUE in any DAW.
            let b1 = g.beat(at: duration)
            jobs = [job(outputs(name: { "\(title)_\($0)_\(bpm)_CUE" }, edited: true),
                        beatStart: 0, beats: b1, stretch: true,
                        acid: .init(tempo: target, beats: Int(b1.rounded(.down)), rootNote: rootNote, loop: false), folder: folder)]
            summary = "stems from the CUE"
        case .loop:
            guard let l = loop else { return }
            let name = "LOOP_" + g.rangeLabel(l.start, l.end).replacingOccurrences(of: "–", with: "_")
            let beats = Double(l.len) / Double(ticksPerBeat)
            jobs = [job(outputs(name: { "\(title)_\($0)_\(bpm)_\(name)" }, edited: true),
                        beatStart: g.firstBarBeat + Double(l.start) / Double(ticksPerBeat), beats: beats, stretch: true,
                        acid: .init(tempo: target, beats: max(1, Int(beats.rounded())), rootNote: rootNote, loop: true), folder: folder)]
            summary = l.isBars ? "loop · \(l.bars) bar\(l.bars == 1 ? "" : "s")" : "loop · \(g.rangeLabel(l.start, l.end))"
        case .regions:
            var used: [String: Int] = [:]
            for r in regionsToExport.sorted(by: { ($0.laneId, $0.start) < ($1.laneId, $1.start) }) {
                guard let lane = Lane.all.first(where: { $0.id == r.laneId }) else { continue }
                let range = g.rangeLabel(r.start, r.end).replacingOccurrences(of: "–", with: "_")
                var name = "\(title)_\(lane.fileTag)_\(bpm)_REGION_\(range)"
                used[name, default: 0] += 1
                if let n = used[name], n > 1 { name += "_\(n)" }
                let p = ExportJob.Part(stems: Dictionary(uniqueKeysWithValues: lane.stems.map { ($0, Float(1)) }),
                                       segs: segments(for: lane.id))
                let out = ExportJob.Output(tag: lane.fileTag, stems: p.stems, parts: [p], name: name)
                let beats = Double(r.len) / Double(ticksPerBeat)
                jobs.append(job([out], beatStart: g.firstBarBeat + Double(r.start) / Double(ticksPerBeat), beats: beats, stretch: true,
                                acid: .init(tempo: target, beats: max(1, Int(beats.rounded())), rootNote: rootNote, loop: true),
                                folder: folder))
            }
            summary = "region\(jobs.count == 1 ? "" : "s")"
        }

        exporting = true
        let all = jobs
        let label = summary
        Task.detached(priority: .userInitiated) {
            let result = Result { try all.flatMap { try Exporter.run($0) } }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.exporting = false
                switch result {
                case .success(let urls):
                    let first = Celebrate.firstExport()
                    self.toast = Toast(text: (first ? "Your first STEMEKI export! 🎉 " : "")
                                       + "\(urls.count) file\(urls.count == 1 ? "" : "s") saved · \(label)", files: urls)
                    Celebrate.shared.filesExported(urls)
                case .failure(let e):
                    self.toast = Toast(text: e.localizedDescription, files: [], isError: true)
                }
            }
        }
    }
}
