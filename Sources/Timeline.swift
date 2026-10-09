import SwiftUI
import AppKit

let rulerHeight: CGFloat = 40
/// The loop lives in the lower strip of the ruler.
let loopBandTop: CGFloat = 22

/// Everything static on the timeline: ruler, bar grid, stem waveforms, loop frame.
/// It does not watch the play clock, so it only redraws when the view or the data changes.
struct TimelineCanvas: View {
    let lanes: [Lane]
    let audible: [String: Bool]
    let peaks: [StemKind: StemPeaks]
    let mixPeaks: StemPeaks?
    let grid: Grid?
    let loopRange: ClosedRange<Double>?
    let loopOn: Bool
    let loopLabel: String?
    let drumStart: Double?
    let regions: [Region]
    /// true: regions are edit selections (cut ranges); false: export regions.
    var editMarks = false
    let cueGhost: Double?
    let selected: Set<UUID>
    let clips: [Clip]
    let segs: [String: [Seg]]
    /// Where ⌘V will paste (seconds), shown while something is copied.
    var pasteAt: Double? = nil
    let viewStart: Double
    let viewLength: Double

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            draw(ctx, size)
        }
    }

    private func x(_ t: Double, _ w: CGFloat) -> CGFloat { CGFloat((t - viewStart) / viewLength) * w }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let w = size.width
        let laneArea = size.height - rulerHeight
        let laneH = laneArea / CGFloat(max(1, lanes.count))
        let viewEnd = viewStart + viewLength

        // Ruler background.
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: rulerHeight)), with: .color(Theme.panel2))

        // Lane backgrounds.
        for (i, lane) in lanes.enumerated() {
            let r = CGRect(x: 0, y: rulerHeight + CGFloat(i) * laneH, width: w, height: laneH)
            ctx.fill(Path(r), with: .color(lane.color.opacity(i % 2 == 0 ? 0.035 : 0.05)))
        }

        // Bar grid: bars, then beats when there is room.
        if let g = grid {
            let pxPerBar = w / CGFloat(viewLength / g.bar)
            let labelEvery = [1, 2, 4, 8, 16, 32, 64].first { CGFloat($0) * pxPerBar >= 38 } ?? 128
            let firstBar = g.barIndex(at: viewStart)
            let lastBar = g.barIndex(at: viewEnd) + 1
            // Eighths and sixteenths when zoomed in close enough (the finer snap lines).
            let pxPerSix = pxPerBar / 16
            if pxPerSix * 2 > 9 {
                var fine = Path(), sixteenths = Path()
                for b in firstBar...lastBar {
                    for k in 1..<16 where k % 4 != 0 {
                        guard k % 2 == 0 || pxPerSix > 9 else { continue }
                        let xx = x(g.time(g.barBeat(b) + Double(k) / 4), w)
                        guard xx >= -2, xx <= w + 2 else { continue }
                        let line = Path { $0.move(to: CGPoint(x: xx, y: rulerHeight)); $0.addLine(to: CGPoint(x: xx, y: size.height)) }
                        if k % 2 == 0 { fine.addPath(line) } else { sixteenths.addPath(line) }
                    }
                }
                ctx.stroke(fine, with: .color(.white.opacity(0.025)), lineWidth: 1)
                ctx.stroke(sixteenths, with: .color(.white.opacity(0.015)), lineWidth: 1)
            }
            if pxPerBar / 4 > 9 {
                var beats = Path()
                for b in firstBar...lastBar {
                    for k in 1..<4 {
                        let xx = x(g.time(g.barBeat(b) + Double(k)), w)
                        beats.move(to: CGPoint(x: xx, y: rulerHeight))
                        beats.addLine(to: CGPoint(x: xx, y: size.height))
                    }
                }
                ctx.stroke(beats, with: .color(.white.opacity(0.035)), lineWidth: 1)
            }
            var bars = Path(), phrases = Path()
            for b in firstBar...lastBar {
                let xx = x(g.barStart(b), w)
                guard xx >= -2, xx <= w + 2 else { continue }
                let isPhrase = ((b - 1) % 16 + 16) % 16 == 0
                let p = Path { $0.move(to: CGPoint(x: xx, y: isPhrase ? 2 : 12)); $0.addLine(to: CGPoint(x: xx, y: size.height)) }
                if isPhrase { phrases.addPath(p) } else if ((b - 1) % labelEvery + labelEvery) % labelEvery == 0 || pxPerBar > 14 { bars.addPath(p) }
                if ((b - 1) % labelEvery + labelEvery) % labelEvery == 0 {
                    ctx.draw(Text("\(b)").font(Theme.mono(10, isPhrase ? .bold : .medium))
                                .foregroundColor(isPhrase ? Theme.text : Theme.dim),
                             at: CGPoint(x: xx + 4, y: 9), anchor: .leading)
                }
            }
            ctx.stroke(bars, with: .color(.white.opacity(0.09)), lineWidth: 1)
            ctx.stroke(phrases, with: .color(.white.opacity(0.2)), lineWidth: 1)

            // The CUE point: the downbeat the grid is counted from.
            let ax = x(g.anchor, w)
            if ax >= 0 && ax <= w {
                ctx.fill(Path(CGRect(x: ax - 0.75, y: rulerHeight, width: 1.5, height: laneArea)),
                         with: .color(Theme.accent.opacity(0.35)))
                let flag = CGRect(x: ax - 27, y: 2, width: 25, height: 12)
                ctx.fill(Path(roundedRect: flag, cornerRadius: 2), with: .color(Theme.accent))
                ctx.draw(Text("CUE").font(Theme.mono(8.5, .heavy)).foregroundColor(.black), at: CGPoint(x: flag.midX, y: flag.midY))
            }

            // Area before bar 1 (pickup) shaded.
            if g.firstBar > viewStart {
                let xx = x(g.firstBar, w)
                ctx.fill(Path(CGRect(x: 0, y: rulerHeight, width: max(0, xx), height: laneArea)), with: .color(.black.opacity(0.25)))
            }
        }

        // Waveforms: true signed min/max contour per Retina pixel, with a brighter RMS core.
        let colStep: CGFloat = 0.5
        let cols = Int((w / colStep).rounded(.up)) + 1
        for (i, lane) in lanes.enumerated() {
            let top = rulerHeight + CGFloat(i) * laneH
            let mid = top + laneH / 2
            let half = laneH / 2 - 6
            let on = audible[lane.id] ?? true
            let laneSegs = segs[lane.id]
            let laneFades = laneSegs?.contains(where: \.hasFades) == true
            // The MIX lane draws the real summed waveform once it is ready.
            let sources = lane.id == Lane.full.id && mixPeaks != nil ? [mixPeaks!] : lane.stems.compactMap { peaks[$0] }
            guard let first = sources.first else { continue }
            let sr = first.sampleRate
            let samplesPerCol = viewLength * sr / Double(cols - 1)
            let levels = sources.map { $0.level(samplesPerColumn: samplesPerCol) }
            // A summed lane (instrumental) can peak above any single stem.
            let norm = max(sources.count > 1 ? (sources.map(\.maxPeak).max() ?? 1) * 1.5 : first.maxPeak, 0.02)
            let scale = half / CGFloat(norm)

            var tops = [CGPoint](), bottoms = [CGPoint](), rmsTop = [CGPoint](), rmsBottom = [CGPoint]()
            tops.reserveCapacity(cols); bottoms.reserveCapacity(cols)
            for c in 0..<cols {
                let x = CGFloat(c) * colStep
                let tl = viewStart + Double(x) / Double(w) * viewLength
                // Edited lane: read where this moment's piece comes from (nothing = deleted).
                guard let st = laneSegs == nil ? tl : grid?.sourceTime(tl, laneSegs) else {
                    tops.append(CGPoint(x: x, y: mid - 0.25)); bottoms.append(CGPoint(x: x, y: mid + 0.25))
                    rmsTop.append(CGPoint(x: x, y: mid - 0.25)); rmsBottom.append(CGPoint(x: x, y: mid + 0.25))
                    continue
                }
                let s0 = st * sr
                let s1 = s0 + samplesPerCol
                var lo: Float = 0, hi: Float = 0, rm: Float = 0
                var any = false
                for l in levels {
                    let bs = Double(l.binSize)
                    let count = l.mins.count
                    if samplesPerCol < bs {
                        // Zoomed past the finest bins: interpolate between bin centres.
                        let f = s0 / bs - 0.5
                        let a = Int(floor(f)), t = Float(f - floor(f))
                        guard a + 1 >= 0, a < count else { continue }
                        let ia = max(0, min(count - 1, a)), ib = max(0, min(count - 1, a + 1))
                        lo += l.mins[ia] + (l.mins[ib] - l.mins[ia]) * t
                        hi += l.maxs[ia] + (l.maxs[ib] - l.maxs[ia]) * t
                        rm += l.rms[ia] + (l.rms[ib] - l.rms[ia]) * t
                        any = true
                    } else {
                        let a = max(0, Int(s0 / bs)), b = min(count, max(a + 1, Int(s1 / bs)))
                        guard b > a else { continue }
                        var mn: Float = .infinity, mx: Float = -.infinity, sq: Float = 0
                        for j in a..<b { mn = min(mn, l.mins[j]); mx = max(mx, l.maxs[j]); sq += l.rms[j] * l.rms[j] }
                        lo += mn; hi += mx; rm += (sq / Float(b - a)).squareRoot()
                        any = true
                    }
                }
                if !any { lo = 0; hi = 0; rm = 0 }
                // Under a fade the waveform shrinks the way it will sound.
                if laneFades, let g = grid {
                    let fg = g.fadeGain(atBeat: g.beat(at: tl), laneSegs)
                    lo *= fg; hi *= fg; rm *= fg
                }
                let yTop = mid - max(0.25, CGFloat(min(hi, norm)) * scale)
                let yBot = mid - min(-0.25, CGFloat(max(lo, -norm)) * scale)
                tops.append(CGPoint(x: x, y: yTop))
                bottoms.append(CGPoint(x: x, y: yBot))
                let r = CGFloat(min(rm, norm)) * scale
                rmsTop.append(CGPoint(x: x, y: max(yTop, mid - r)))
                rmsBottom.append(CGPoint(x: x, y: min(yBot, mid + r)))
            }
            func band(_ upper: [CGPoint], _ lower: [CGPoint]) -> Path {
                var p = Path()
                guard let f = upper.first else { return p }
                p.move(to: f)
                for pt in upper.dropFirst() { p.addLine(to: pt) }
                for pt in lower.reversed() { p.addLine(to: pt) }
                p.closeSubpath()
                return p
            }
            func line(_ pts: [CGPoint]) -> Path {
                var p = Path()
                guard let f = pts.first else { return p }
                p.move(to: f)
                for pt in pts.dropFirst() { p.addLine(to: pt) }
                return p
            }
            let color = on ? lane.color : Color.gray
            let laneRect = CGRect(x: 0, y: top, width: w, height: laneH)
            let outer = band(tops, bottoms)
            ctx.fill(outer, with: .linearGradient(
                Gradient(colors: [color.opacity(on ? 0.55 : 0.18), color.opacity(on ? 0.22 : 0.08), color.opacity(on ? 0.55 : 0.18)]),
                startPoint: CGPoint(x: 0, y: laneRect.minY + 6), endPoint: CGPoint(x: 0, y: laneRect.maxY - 6)))
            ctx.fill(band(rmsTop, rmsBottom), with: .color(color.opacity(on ? 0.92 : 0.28)))
            ctx.stroke(line(tops), with: .color(color.opacity(on ? 0.9 : 0.3)), lineWidth: 0.6)
            ctx.stroke(line(bottoms), with: .color(color.opacity(on ? 0.9 : 0.3)), lineWidth: 0.6)
            // Lane separator.
            ctx.fill(Path(CGRect(x: 0, y: top, width: w, height: 1)), with: .color(Theme.line))
        }

        // Regions marked on the lanes.
        if let g = grid {
            for r in regions {
                guard let li = lanes.firstIndex(where: { $0.id == r.laneId }) else { continue }
                let lane = lanes[li]
                let x0 = x(g.tickTime(r.start), w), x1 = x(g.tickTime(r.end), w)
                guard x1 >= 0, x0 <= w else { continue }
                let top = rulerHeight + CGFloat(li) * laneH
                let rect = CGRect(x: x0, y: top + 3, width: x1 - x0, height: laneH - 6)
                let sel = selected.contains(r.id)
                if editMarks {
                    // A range to cut: cyan, dashed.
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(Theme.accent.opacity(sel ? 0.2 : 0.12)))
                    ctx.stroke(Path(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 4),
                               with: .color(Theme.accent), style: StrokeStyle(lineWidth: sel ? 2 : 1.5, dash: [6, 4]))
                } else {
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(lane.color.opacity(sel ? 0.26 : 0.16)))
                    ctx.stroke(Path(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 4),
                               with: .color(sel ? Color.white : lane.color), lineWidth: sel ? 2 : 1.2)
                }
                let tag = CGRect(x: max(x0, 0) + 4, y: top + 7, width: 0, height: 0)
                if x1 - x0 > 34 {
                    ctx.draw(Text((editMarks ? "✂ " : "⬇ ") + g.rangeLabel(r.start, r.end)).font(Theme.mono(9.5, .bold))
                                .foregroundColor(editMarks ? Theme.accent : (sel ? .white : lane.color)),
                             at: CGPoint(x: tag.minX, y: tag.minY + 5), anchor: .leading)
                }
                for xx in [x0, x1] {
                    ctx.fill(Path(roundedRect: CGRect(x: xx - 2, y: rect.midY - 12, width: 4, height: 24), cornerRadius: 2),
                             with: .color(editMarks ? Theme.accent : (sel ? Color.white : lane.color)))
                }
            }
        }

        // Edited pieces: thin frames, selected ones white.
        if let g = grid {
            for c in clips {
                guard let li = lanes.firstIndex(where: { $0.id == c.laneId }) else { continue }
                let lane = lanes[li]
                let x0 = x(g.tickTime(c.start), w), x1 = x(g.tickTime(c.end), w)
                guard x1 >= 0, x0 <= w else { continue }
                let top = rulerHeight + CGFloat(li) * laneH
                let rect = CGRect(x: x0, y: top + 2, width: x1 - x0, height: laneH - 4)
                let sel = selected.contains(c.id)
                if sel { ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(Color.white.opacity(0.08))) }
                ctx.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 3),
                           with: .color(sel ? Color.white : lane.color.opacity(0.55)), lineWidth: sel ? 2 : 1)
                // Fades: the faded part darkened above a quarter-sine curve, and (EDIT) a handle on each top corner.
                let sb = g.firstBarBeat + Double(c.start) / Double(ticksPerBeat)
                let eb = g.firstBarBeat + Double(c.end) / Double(ticksPerBeat)
                let fi = x(g.time(sb + c.fadeIn), w), fo = x(g.time(eb - c.fadeOut), w)
                func fade(_ from: CGFloat, _ to: CGFloat, rising: Bool) {
                    guard abs(to - from) > 0.5 else { return }
                    var curve = Path(), shade = Path()
                    shade.move(to: CGPoint(x: from, y: rect.minY))
                    for k in 0...32 {
                        let u = CGFloat(k) / 32
                        let gain = sin(Double(rising ? u : 1 - u) * .pi / 2)
                        let pt = CGPoint(x: from + (to - from) * u, y: rect.maxY - CGFloat(gain) * rect.height)
                        if k == 0 { curve.move(to: pt) } else { curve.addLine(to: pt) }
                        shade.addLine(to: pt)
                    }
                    shade.addLine(to: CGPoint(x: to, y: rect.minY))
                    shade.closeSubpath()
                    ctx.fill(shade, with: .color(.black.opacity(0.38)))
                    ctx.stroke(curve, with: .color(.white.opacity(0.85)), lineWidth: 1.2)
                }
                if c.fadeIn > 0 { fade(x0, fi, rising: true) }
                if c.fadeOut > 0 { fade(fo, x1, rising: false) }
                if editMarks, x1 - x0 > 24 {
                    for (hx, on) in [(fi, c.fadeIn > 0), (fo, c.fadeOut > 0)] {
                        let hxx = max(x0 + 1, min(x1 - 8, hx - 3.5))
                        let h = CGRect(x: hxx, y: rect.minY + 1, width: 7, height: 7)
                        ctx.fill(Path(roundedRect: h, cornerRadius: 1.5), with: .color(on || sel ? .white : lane.color.opacity(0.8)))
                    }
                    if sel {
                        for (hx, f, right) in [(fi, c.fadeIn, false), (fo, c.fadeOut, true)] where f > 0 {
                            let ms = (right ? g.time(eb) - g.time(eb - f) : g.time(sb + f) - g.time(sb)) * 1000
                            let label = ms >= 1000 ? String(format: "%.2f s", ms / 1000) : String(format: "%.0f ms", ms)
                            ctx.draw(Text(label).font(Theme.mono(9, .bold)).foregroundColor(.white),
                                     at: CGPoint(x: hx + (right ? -6 : 6), y: rect.minY + 16), anchor: right ? .trailing : .leading)
                        }
                    }
                }
            }
        }

        // The paste point (⌘V).
        if let pa = pasteAt {
            let px = x(pa, w)
            if px >= 0 && px <= w {
                var dash = Path()
                dash.move(to: CGPoint(x: px, y: rulerHeight)); dash.addLine(to: CGPoint(x: px, y: size.height))
                ctx.stroke(dash, with: .color(.white.opacity(0.75)), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                let tag = CGRect(x: px + 3, y: rulerHeight + 3, width: 26, height: 13)
                ctx.fill(Path(roundedRect: tag, cornerRadius: 3), with: .color(.white))
                ctx.draw(Text("⌘V").font(Theme.mono(8.5, .heavy)).foregroundColor(.black), at: CGPoint(x: tag.midX, y: tag.midY))
            }
        }

        // CUE being dragged: a dashed line and a faded flag where it will land.
        if let cg = cueGhost {
            let gx = x(cg, w)
            var dash = Path()
            dash.move(to: CGPoint(x: gx, y: 0)); dash.addLine(to: CGPoint(x: gx, y: size.height))
            ctx.stroke(dash, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            let flag = CGRect(x: gx - 27, y: 2, width: 25, height: 12)
            ctx.fill(Path(roundedRect: flag, cornerRadius: 2), with: .color(Theme.accent.opacity(0.6)))
            ctx.draw(Text("CUE").font(Theme.mono(8.5, .heavy)).foregroundColor(.black), at: CGPoint(x: flag.midX, y: flag.midY))
        }

        // Loop: only in the ruler's lower strip.
        if let r = loopRange {
            let x0 = x(r.lowerBound, w), x1 = x(r.upperBound, w)
            let band = CGRect(x: x0, y: loopBandTop, width: x1 - x0, height: rulerHeight - loopBandTop - 3)
            if loopOn {
                ctx.fill(Path(roundedRect: band, cornerRadius: 3), with: .color(Theme.loop.opacity(0.9)))
            } else {
                ctx.fill(Path(roundedRect: band, cornerRadius: 3), with: .color(Theme.loop.opacity(0.12)))
                ctx.stroke(Path(roundedRect: band.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 3), with: .color(Theme.loop.opacity(0.45)), lineWidth: 1)
            }
            for xx in [x0, x1] {
                ctx.fill(Path(roundedRect: CGRect(x: xx - 2, y: loopBandTop - 2, width: 4, height: band.height + 4), cornerRadius: 2),
                         with: .color(Theme.loop.opacity(loopOn ? 1 : 0.5)))
            }
            if let loopLabel, x1 - x0 > 50 {
                ctx.draw(Text(loopLabel).font(Theme.mono(9, .bold)).foregroundColor(loopOn ? .black : Theme.loop.opacity(0.7)),
                         at: CGPoint(x: max(x0, 0) + 6, y: band.midY), anchor: .leading)
            }
        }
    }
}

/// The playhead line; watches the play clock on its own.
struct PlayheadLayer: View {
    @ObservedObject var clock: PlayClock
    let viewStart: Double
    let viewLength: Double

    var body: some View {
        GeometryReader { geo in
            let xx = CGFloat((clock.position - viewStart) / viewLength) * geo.size.width
            if xx >= 0 && xx <= geo.size.width {
                ZStack(alignment: .top) {
                    Rectangle().fill(Color.white).frame(width: 1.5)
                    Triangle().fill(Color.white).frame(width: 11, height: 7)
                }
                .frame(width: 11)
                .offset(x: xx - 5.5)
                .shadow(color: .black.opacity(0.6), radius: 2)
            }
        }
        .allowsHitTesting(false)
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.closeSubpath()
        }
    }
}

// MARK: - Mouse, trackpad and scroll handling

final class TimelineNSView: NSView {
    weak var coordinator: TimelineInteraction.Coordinator?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with e: NSEvent) {
        // Clicking the timeline takes the keyboard away from the BPM field.
        window?.makeFirstResponder(self)
        coordinator?.down(point(e), size: bounds.size, clicks: e.clickCount, mods: e.modifierFlags)
    }
    /// Fallback when the shortcut was not taken by a button: space, L and the arrows.
    override func keyDown(with e: NSEvent) {
        guard let c = coordinator else { return super.keyDown(with: e) }
        let cmd = e.modifierFlags.contains(.command)
        if cmd {
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "z": e.modifierFlags.contains(.shift) ? c.session.redo() : c.session.undo(); return
            case "d": c.session.duplicateSelected(); return
            case "c": c.session.copySelection(); return
            case "v": c.session.paste(); return
            case "a": c.session.selectAll(); return
            default: return super.keyDown(with: e)
            }
        }
        switch e.keyCode {
        case 49: c.session.player.toggle()
        case 37: c.session.loopEnabled.toggle()
        case 123: c.session.shiftLoop(-1)
        case 124: c.session.shiftLoop(1)
        case 51, 117: c.deleteSelection()
        case 53: c.session.clearSelection()
        case 32:   // U: the loop takes the selection's start and end
            c.session.loopToSelection()
        case 14:   // E: EDIT / EXPORT
            c.session.workMode = c.session.workMode == .edit ? .export : .edit
        default: super.keyDown(with: e)
        }
    }

    override func mouseDragged(with e: NSEvent) { coordinator?.drag(point(e), size: bounds.size) }
    override func mouseUp(with e: NSEvent) { coordinator?.up(point(e), size: bounds.size) }
    override func mouseMoved(with e: NSEvent) { coordinator?.cursor(at: point(e), size: bounds.size).set() }
    override func cursorUpdate(with e: NSEvent) { coordinator?.cursor(at: point(e), size: bounds.size).set() }
    override func scrollWheel(with e: NSEvent) { coordinator?.scroll(e, at: point(e), size: bounds.size) }
    override func magnify(with e: NSEvent) { coordinator?.magnify(e.magnification, at: point(e), size: bounds.size) }
}

struct TimelineInteraction: NSViewRepresentable {
    let session: Session

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> TimelineNSView {
        let v = TimelineNSView()
        v.coordinator = context.coordinator
        return v
    }

    func updateNSView(_ v: TimelineNSView, context: Context) {
        context.coordinator.session = session
        v.coordinator = context.coordinator
    }

    @MainActor
    final class Coordinator {
        var session: Session
        init(session: Session) { self.session = session }

        /// What a drag edits: the loop (ruler) or a region (lane).
        private enum Target: Equatable { case loop; case region(UUID) }

        private enum Drag {
            case none, scrub
            case pending(Double, laneId: String?, clip: UUID?)  // empty spot or an unselected piece
            case pendingLoop(Double)
            case pendingRegion(Double, UUID)                   // click = cut there
            case pendingClip(Double, UUID)                     // a selected piece
            case create(Double, Target)
            case move(Double, Int, Int, Target)                // loop: t0, original start, bars
            case regions(Double, CGFloat, [Region])            // t0, y0, their state at the start
            case clips(Double, [Clip])                         // t0, their state at the start
            case resizeStart(Int, Target)                      // fixed end (exclusive)
            case resizeEnd(Int, Target)                        // fixed start
            case cue                                           // dragging the CUE flag
            case trimStart(Double, Clip)                       // EDIT: a piece's start edge
            case trimEnd(Double, Clip)                         // EDIT: a piece's end edge
            case fade(Clip, Bool)                              // EDIT: a piece's fade-in (true) / fade-out handle
        }

        private var drag: Drag = .none
        private var downPoint: CGPoint = .zero
        private var downMods: NSEvent.ModifierFlags = []

        private func time(_ x: CGFloat, _ w: CGFloat) -> Double {
            session.viewStart + Double(x / max(w, 1)) * session.viewLength
        }

        private func xOf(_ t: Double, _ w: CGFloat) -> CGFloat {
            CGFloat((t - session.viewStart) / session.viewLength) * w
        }

        private func laneIndex(at p: CGPoint, _ size: CGSize) -> Int? {
            let n = session.lanes.count
            let h = (size.height - rulerHeight) / CGFloat(max(1, n))
            let i = Int((p.y - rulerHeight) / h)
            return p.y >= rulerHeight && i >= 0 && i < n ? i : nil
        }

        private func lane(at p: CGPoint, _ size: CGSize) -> Lane? {
            laneIndex(at: p, size).map { session.lanes[$0] }
        }

        private func laneHeight(_ size: CGSize) -> CGFloat {
            (size.height - rulerHeight) / CGFloat(max(1, session.lanes.count))
        }

        private enum Hit { case startEdge(Target, Int, Int), endEdge(Target, Int, Int), inside(Target, Int, Int), empty }

        /// The loop band in the ruler, or a region on the lane (regions lie above the pieces).
        private func hit(_ p: CGPoint, _ size: CGSize) -> Hit {
            guard let g = session.grid else { return .empty }
            var spans: [(Target, Int, Int)] = []
            if p.y < rulerHeight {
                guard p.y >= loopBandTop - 4, let l = session.loop else { return .empty }
                spans = [(.loop, l.start, l.len)]
            } else if let lane = lane(at: p, size) {
                spans = session.regions.filter { $0.laneId == lane.id }
                    .sorted { session.selected.contains($0.id) && !session.selected.contains($1.id) }
                    .map { (.region($0.id), $0.start, $0.len) }
            }
            for (tg, s, n) in spans {
                let x0 = xOf(g.tickTime(s), size.width), x1 = xOf(g.tickTime(s + n), size.width)
                if abs(p.x - x0) < 6 { return .startEdge(tg, s, n) }
                if abs(p.x - x1) < 6 { return .endEdge(tg, s, n) }
            }
            for (tg, s, n) in spans {
                let x0 = xOf(g.tickTime(s), size.width), x1 = xOf(g.tickTime(s + n), size.width)
                if p.x > x0 && p.x < x1 { return .inside(tg, s, n) }
            }
            return .empty
        }

        /// The top piece under the mouse on an edited lane.
        private func clip(at p: CGPoint, _ size: CGSize) -> Clip? {
            guard let g = session.grid, let lane = lane(at: p, size) else { return nil }
            let b = Int(floor(g.tick(at: time(p.x, size.width))))
            return session.clips.last { $0.laneId == lane.id && b >= $0.start && b < $0.end }
        }

        func cursor(at p: CGPoint, size: CGSize) -> NSCursor {
            if fadeHandle(p, size) != nil { return .pointingHand }
            switch hit(p, size) {
            case .startEdge, .endEdge: return .resizeLeftRight
            case .inside(.region, _, _): return NSEvent.modifierFlags.contains(.option) ? .dragCopy : .pointingHand
            case .inside: return .openHand
            case .empty:
                if p.y < loopBandTop - 4 { return overCue(p, size) ? .openHand : .pointingHand }
                if clipEdge(p, size) != nil { return .resizeLeftRight }
                if p.y < rulerHeight { return .crosshair }
                if session.workMode == .edit, let c = clip(at: p, size), session.selected.contains(c.id) {
                    return NSEvent.modifierFlags.contains(.option) ? .dragCopy : .openHand
                }
                return .arrow
            }
        }

        /// Start/length in ticks.
        private func apply(_ target: Target, start: Int, len: Int) {
            switch target {
            case .loop:
                if let l = session.clampLoop(LoopSelection(start: start, len: len)), l != session.loop { session.loop = l }
            case .region(let id):
                session.setRegion(id, start: start, len: len)
            }
        }

        /// Snap step in ticks, by zoom: sixteenths, eighths, beats or whole bars, whichever is wide enough
        /// on screen. The loop snaps to bars, unless it is finer already (made with U).
        private func unit(_ target: Target?, _ size: CGSize) -> Int {
            if case .loop = target, session.loop?.isBars ?? true { return ticksPerBar }
            guard let g = session.grid else { return ticksPerBar }
            let pxPerBeat = Double(size.width) / (session.viewLength / g.beat)
            if pxPerBeat / 4 >= 14 { return 1 }
            if pxPerBeat / 2 >= 14 { return 2 }
            return pxPerBeat >= 20 ? ticksPerBeat : ticksPerBar
        }

        func down(_ p: CGPoint, size: CGSize, clicks: Int, mods: NSEvent.ModifierFlags) {
            downPoint = p
            downMods = mods
            let t = time(p.x, size.width)
            guard let g = session.grid else { session.player.seek(t); drag = .scrub; return }
            // A fade handle on a piece's top corner: drag to set the fade, double-click to remove it.
            if let (c, isIn) = fadeHandle(p, size) {
                session.checkpoint()
                session.selected = [c.id]
                if clicks == 2 {
                    isIn ? session.setFades(c, fadeIn: 0) : session.setFades(c, fadeOut: 0)
                    drag = .none
                } else {
                    drag = .fade(c, isIn)
                }
                return
            }
            let h = hit(p, size)
            if clicks == 2 {
                if p.y < rulerHeight {
                    // Double-click on the loop removes it; elsewhere in the strip: a one-bar loop.
                    if case .inside(.loop, _, _) = h { session.loop = nil }
                    else if p.y >= loopBandTop - 4, let l = session.clampLoop(LoopSelection(startBar: g.barIndex(at: t), bars: 1)) {
                        session.loop = l
                        session.loopEnabled = true
                    }
                } else if let lane = lane(at: p, size), case .empty = h {
                    let u = unit(nil, size)
                    let s = Int(floor(g.tick(at: t) / Double(u))) * u
                    session.addRegion(lane: lane, start: s, len: u)
                }
                drag = .none
                return
            }
            // The CUE flag (or its line) in the bar-numbers strip: drag it; double-click puts it back on the drums.
            if p.y < loopBandTop - 4, overCue(p, size) {
                if clicks == 2 { session.autoCue(); drag = .none; return }
                drag = .cue
                session.cueGhost = g.anchor
                return
            }
            // Bar numbers strip: scrub.
            if p.y < loopBandTop - 4 {
                session.player.seek(t)
                drag = .scrub
                return
            }
            switch h {
            case .startEdge(let tg, let s, let n):
                selectRegion(tg, mods); session.checkpoint(); drag = .resizeStart(s + n, tg)
            case .endEdge(let tg, let s, _):
                selectRegion(tg, mods); session.checkpoint(); drag = .resizeEnd(s, tg)
            case .inside(.loop, _, _):
                drag = .pendingLoop(t)
            case .inside(.region(let id), _, _):
                selectRegion(.region(id), mods)
                drag = .pendingRegion(t, id)
            case .empty:
                guard p.y >= rulerHeight else { drag = .pending(t, laneId: nil, clip: nil); return }
                if let (c, isStart) = clipEdge(p, size) {
                    session.checkpoint()
                    session.selected = [c.id]
                    drag = isStart ? .trimStart(t, c) : .trimEnd(t, c)
                    return
                }
                let c = session.workMode == .edit ? clip(at: p, size) : nil
                if let c, session.selected.contains(c.id) {
                    if mods.contains(.shift) { session.selected.remove(c.id); drag = .none; return }
                    drag = .pendingClip(t, c.id)
                } else if let c, mods.contains(.shift) {
                    session.selected.insert(c.id)
                    drag = .none
                } else {
                    drag = .pending(t, laneId: lane(at: p, size)?.id, clip: c?.id)
                }
            }
        }

        private func selectRegion(_ tg: Target, _ mods: NSEvent.ModifierFlags) {
            guard case .region(let id) = tg else { return }
            if mods.contains(.shift) {
                if session.selected.contains(id) { session.selected.remove(id) } else { session.selected.insert(id) }
            } else if !session.selected.contains(id) {
                session.selected = [id]
            }
        }

        func drag(_ p: CGPoint, size: CGSize) {
            let t = time(p.x, size.width)
            let moved = abs(p.x - downPoint.x) > 3 || abs(p.y - downPoint.y) > 3
            guard let g = session.grid else {
                if case .scrub = drag { session.player.seek(t) }
                return
            }
            /// Nearest snap line (in ticks) to time x.
            func snap(_ x: Double, _ u: Int) -> Int { Int((g.tick(at: x) / Double(u)).rounded()) * u }
            func span(_ a: Double, _ b: Double, _ u: Int) -> (Int, Int) {
                let s = snap(min(a, b), u)
                let e = max(s + u, snap(max(a, b), u))
                return (s, e - s)
            }
            func delta(_ t0: Double, _ u: Int) -> Int { Int(((g.tick(at: t) - g.tick(at: t0)) / Double(u)).rounded()) * u }
            switch drag {
            case .none: break
            case .scrub: session.player.seek(t)
            case .pending(let t0, let laneId, _):
                guard moved else { return }
                if let laneId, let lane = session.lanes.first(where: { $0.id == laneId }) {
                    let (s, n) = span(t0, t, unit(nil, size))
                    let id = session.addRegion(lane: lane, start: s, len: n)
                    drag = .create(t0, .region(id))
                } else {
                    let (s, n) = span(t0, t, ticksPerBar)
                    session.loopEnabled = true
                    apply(.loop, start: s, len: n)
                    drag = .create(t0, .loop)
                }
            case .pendingLoop(let t0):
                guard moved else { return }
                drag = .move(t0, session.loop?.start ?? 0, session.loop?.len ?? ticksPerBar, .loop)
                NSCursor.closedHand.set()
            case .pendingRegion(let t0, _):
                guard moved else { return }
                let base: [Region]
                if downMods.contains(.option) {
                    base = session.duplicateSelected(place: false).regions
                } else {
                    session.checkpoint()
                    base = session.regions.filter { session.selected.contains($0.id) }
                }
                drag = .regions(t0, downPoint.y, base)
                NSCursor.closedHand.set()
            case .pendingClip(let t0, _):
                guard moved else { return }
                let base: [Clip]
                if downMods.contains(.option) {
                    base = session.duplicateSelected(place: false).clips
                } else {
                    session.checkpoint()
                    base = session.clips.filter { session.selected.contains($0.id) }
                }
                drag = .clips(t0, base)
                NSCursor.closedHand.set()
            case .create(let t0, let tg):
                let (s, n) = span(t0, t, unit(tg, size))
                apply(tg, start: s, len: n)
            case .move(let t0, let s0, let n, let tg):
                apply(tg, start: s0 + delta(t0, unit(tg, size)), len: n)
            case .regions(let t0, let y0, let base):
                let lanes = Int(((p.y - y0) / laneHeight(size)).rounded())
                session.moveRegions(base, ticks: delta(t0, unit(nil, size)), lanes: lanes)
            case .clips(let t0, let base):
                session.moveClips(base, ticks: delta(t0, unit(nil, size)))
            case .cue:
                session.cueGhost = g.time(cueTarget(t, size))
            case .fade(let c, let isIn):
                // Free (not snapped): fades are by ear.
                let b = g.beat(at: t)
                if isIn {
                    session.setFades(c, fadeIn: max(0, b - (g.firstBarBeat + Double(c.start) / Double(ticksPerBeat))))
                } else {
                    session.setFades(c, fadeOut: max(0, g.firstBarBeat + Double(c.end) / Double(ticksPerBeat) - b))
                }
            case .trimStart(_, let c):
                let u = unit(nil, size)
                session.trimClip(c, start: snap(t, u))
            case .trimEnd(_, let c):
                let u = unit(nil, size)
                session.trimClip(c, end: snap(t, u))
            case .resizeStart(let end, let tg):
                let u = unit(tg, size)
                let s = min(snap(t, u), end - u)
                apply(tg, start: s, len: end - s)
            case .resizeEnd(let start, let tg):
                let u = unit(tg, size)
                let e = max(snap(t, u), start + u)
                apply(tg, start: start, len: e - start)
            }
        }

        func up(_ p: CGPoint, size: CGSize) {
            let t = time(p.x, size.width)
            switch drag {
            case .pending(_, let laneId, let clip):
                // A click on a piece selects it; on empty space it moves the playhead (and on a lane,
                // it is where ⌘V pastes, on the nearest snap line).
                if let clip {
                    session.selected = [clip]
                } else {
                    session.selected = []
                    session.player.seek(t)
                    if laneId != nil, let g = session.grid {
                        let u = unit(nil, size)
                        session.pasteAt = Int((g.tick(at: t) / Double(u)).rounded()) * u
                    }
                }
            case .pendingLoop: session.player.seek(t)
            case .pendingRegion(_, let id):
                // EDIT: a click inside the selection cuts the audio at its start and end.
                // EXPORT: a click only selects the region.
                if !downMods.contains(.shift) && session.workMode == .edit { session.cutAtRegion(id) }
            case .pendingClip(_, let id):
                session.selected = [id]
            case .clips(_, let base):
                session.resolveOverlaps(Set(base.map(\.id)))
            case .trimStart(_, let c), .trimEnd(_, let c):
                session.resolveOverlaps([c.id])
            case .cue:
                if let g = session.grid {
                    let k = cueTarget(t, size)
                    if abs(k) > 1e-9 { session.moveCue(toBeat: k) }
                    _ = g
                }
                session.cueGhost = nil
            default: break
            }
            drag = .none
        }

        func deleteSelection() { session.deleteSelected() }

        /// EDIT: a piece edge under the mouse (selected pieces first, then the top one).
        private func clipEdge(_ p: CGPoint, _ size: CGSize) -> (Clip, Bool)? {
            guard session.workMode == .edit, let g = session.grid, let lane = lane(at: p, size) else { return nil }
            let mine = session.clips.filter { $0.laneId == lane.id }
            let ordered = mine.filter { session.selected.contains($0.id) } + mine.reversed()
            for c in ordered {
                let x0 = xOf(g.tickTime(c.start), size.width), x1 = xOf(g.tickTime(c.end), size.width)
                guard x1 - x0 > 14 else { continue }
                if abs(p.x - x0) < 5 { return (c, true) }
                if abs(p.x - x1) < 5 { return (c, false) }
            }
            return nil
        }

        /// EDIT: a fade handle (top corner square of a piece) under the mouse; true = fade-in.
        private func fadeHandle(_ p: CGPoint, _ size: CGSize) -> (Clip, Bool)? {
            guard session.workMode == .edit, let g = session.grid, let li = laneIndex(at: p, size) else { return nil }
            let lane = session.lanes[li]
            let top = rulerHeight + CGFloat(li) * laneHeight(size) + 2
            guard p.y >= top - 2, p.y <= top + 13 else { return nil }
            let mine = session.clips.filter { $0.laneId == lane.id }
            for c in mine.filter({ session.selected.contains($0.id) }) + mine.reversed() {
                let x0 = xOf(g.tickTime(c.start), size.width), x1 = xOf(g.tickTime(c.end), size.width)
                guard x1 - x0 > 24 else { continue }
                let sb = g.firstBarBeat + Double(c.start) / Double(ticksPerBeat)
                let eb = g.firstBarBeat + Double(c.end) / Double(ticksPerBeat)
                let fi = max(x0 + 4.5, min(x1 - 4.5, xOf(g.time(sb + c.fadeIn), size.width)))
                let fo = max(x0 + 4.5, min(x1 - 4.5, xOf(g.time(eb - c.fadeOut), size.width)))
                if abs(p.x - fi) <= 6 { return (c, true) }
                if abs(p.x - fo) <= 6 { return (c, false) }
            }
            return nil
        }

        /// Is the mouse on the CUE flag or its line (in the bar-numbers strip)?
        private func overCue(_ p: CGPoint, _ size: CGSize) -> Bool {
            guard let g = session.grid else { return false }
            let ax = xOf(g.anchor, size.width)
            return (p.x >= ax - 29 && p.x <= ax + 3)
        }

        /// Where a dragged CUE lands, as a beat in the current numbering: the nearest beat line,
        /// or with ⌥ the nearest real hit (anywhere).
        private func cueTarget(_ t: Double, _ size: CGSize) -> Double {
            guard let g = session.grid else { return 0 }
            if NSEvent.modifierFlags.contains(.option) {
                let secPerPx = session.viewLength / Double(max(size.width, 1))
                let hit = session.nearestHit(to: t, stems: nil, maxDist: 15 * secPerPx) ?? t
                return g.beat(at: hit)
            }
            return g.beat(at: t).rounded()
        }

        func scroll(_ e: NSEvent, at p: CGPoint, size: CGSize) {
            let w = max(size.width, 1)
            let scale: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 12
            if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option) {
                let f = exp(Double(-e.scrollingDeltaY * scale) * 0.01)
                session.zoom(by: f, around: time(p.x, w))
                return
            }
            let dx = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY
            session.scroll(by: -Double(dx * scale / w) * session.viewLength)
        }

        func magnify(_ m: CGFloat, at p: CGPoint, size: CGSize) {
            session.zoom(by: Double(1 / (1 + m)), around: time(p.x, max(size.width, 1)))
        }
    }
}

/// Whole-song overview with the visible window, the loop and the playhead.
struct OverviewStrip: View {
    @ObservedObject var session: Session
    @ObservedObject var clock: PlayClock
    let peaks: [StemKind: StemPeaks]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let d = max(session.duration, 0.001)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    drawOverview(ctx, size)
                }
                // Visible window.
                // The visible window, kept inside the strip (the view may start before the song).
                let rawX = CGFloat(session.viewStart / d) * w
                let rawEnd = CGFloat((session.viewStart + session.viewLength) / d) * w
                let vx = max(0, rawX)
                let vw = max(6, min(w, rawEnd) - vx)
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.white.opacity(0.55), lineWidth: 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.06)))
                    .frame(width: vw, height: h - 2)
                    .offset(x: vx, y: 1)
                Rectangle().fill(Color.white).frame(width: 1.5, height: h)
                    .offset(x: CGFloat(clock.position / d) * w)
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let t = Double(v.location.x / w) * d
                session.viewStart = session.clampView(t - session.viewLength / 2)
            })
        }
    }

    private func drawOverview(_ ctx: GraphicsContext, _ size: CGSize) {
        let d = max(session.duration, 0.001)
        let lanes = Lane.lanes(for: .four)
        let cols = Int(size.width)
        guard cols > 0 else { return }
        // Stacked: each stem's share of the column, in its color.
        let all = lanes.compactMap { lane in peaks[lane.stems[0]].map { (lane, $0) } }
        guard let ref = all.first?.1 else { return }
        let globalMax = max(all.map { $0.1.maxPeak }.reduce(0, +), 0.05)
        let bps = ref.sampleRate / Double(ref.levels[2].binSize)
        var paths = Array(repeating: Path(), count: all.count)
        for c in 0..<cols {
            let lo = Int(Double(c) / Double(cols) * d * bps)
            let hi = max(lo + 1, Int(Double(c + 1) / Double(cols) * d * bps))
            var y = size.height
            for (i, (_, pk)) in all.enumerated() {
                var r: Float = 0
                let lv = pk.levels[2]
                // Past the song (pieces moved beyond its end) there is no overview data.
                if lo < lv.rms.count { for j in lo..<min(hi, lv.rms.count) { r = max(r, lv.rms[j]) } }
                let hgt = CGFloat(r / globalMax) * size.height * 1.6
                paths[i].addRect(CGRect(x: CGFloat(c), y: y - hgt, width: 1, height: hgt))
                y -= hgt
            }
        }
        for (i, (lane, _)) in all.enumerated() { ctx.fill(paths[i], with: .color(lane.color.opacity(0.75))) }
        if let r = session.loopRange {
            let x0 = CGFloat(r.lowerBound / d) * size.width, x1 = CGFloat(r.upperBound / d) * size.width
            ctx.fill(Path(CGRect(x: x0, y: 0, width: max(2, x1 - x0), height: size.height)), with: .color(Theme.loop.opacity(0.25)))
            ctx.fill(Path(CGRect(x: x0, y: 0, width: max(2, x1 - x0), height: 3)), with: .color(Theme.loop))
        }
    }
}
