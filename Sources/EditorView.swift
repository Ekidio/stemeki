import SwiftUI
import AppKit

struct EditorView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var session: Session
    @ObservedObject var player: StemPlayer

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            OverviewStrip(session: session, clock: player.clock, peaks: player.peaks)
                .frame(height: 38)
                .background(Theme.panel)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            HStack(spacing: 0) {
                LaneHeaders(clock: player.clock)
                    .frame(width: 200)
                timeline
            }
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
            .padding(.horizontal, 14)
            ControlDeck(clock: player.clock)
                .padding(14)
        }
        .overlay(alignment: .bottom) { ToastView() }
        .background(FollowDriver(clock: player.clock))
        .onChange(of: player.hits.count) { _, _ in session.autoWarpIfNeeded() }
        .onAppear { session.autoWarpIfNeeded() }
    }

    private var timeline: some View {
        let song = library.selected
        let lanes = session.lanes
        var audible: [String: Bool] = [:]
        var laneSegs: [String: [Seg]] = [:]
        for l in lanes { if let sg = session.segments(for: l.id) { laneSegs[l.id] = sg } }
        for l in lanes { audible[l.id] = session.isAudible(l) }
        let loopLabel: String? = session.loop.map { l in
            l.whole ? "FULL SONG · \(l.bars) bars" : "\(l.startBar)–\(l.endBar - 1) · \(l.bars) bar\(l.bars == 1 ? "" : "s")"
        }
        return ZStack {
            TimelineCanvas(lanes: lanes, audible: audible, peaks: player.peaks, mixPeaks: player.mixPeaks, grid: song?.grid,
                           loopRange: session.loopRange, loopOn: session.loopEnabled, loopLabel: loopLabel,
                           drumStart: song?.drumStart, regions: session.regions, editMarks: session.workMode == .edit, cueGhost: session.cueGhost, selected: session.selected,
                           clips: session.clips, segs: laneSegs,
                           viewStart: session.viewStart, viewLength: session.viewLength)
            PlayheadLayer(clock: player.clock, viewStart: session.viewStart, viewLength: session.viewLength)
            TimelineInteraction(session: session)
            if !session.selected.isEmpty || !session.clips.isEmpty {
                RegionToolbar().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(10)
            }
            if player.peaks.isEmpty {
                ProgressView().controlSize(.small)
            }
        }
        .clipped()
    }
}

/// Keeps the view paging along with the playhead.
private struct FollowDriver: View {
    @EnvironmentObject var session: Session
    @ObservedObject var clock: PlayClock
    var body: some View {
        Color.clear.onChange(of: clock.position) { _, _ in session.followPlayhead() }
    }
}

// MARK: - Header

struct HeaderBar: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var session: Session

    var body: some View {
        let song = library.selected
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(song?.title ?? "").font(.system(size: 19, weight: .bold)).lineLimit(1)
                HStack(spacing: 8) {
                    if let g = song?.grid {
                        Stat(label: "BPM", value: formatBPM(session.outputBPM ?? g.meanBPM), color: Theme.accent)
                        Stat(label: "SONG", value: String(format: "≈%.2f", g.meanBPM), color: Theme.dim)
                        if session.pinCount > 0 {
                            Stat(label: "WARP", value: "\(session.pinCount) pins", color: Theme.instrumental)
                        }
                        if let sh = song?.contentShift, abs(sh) > 1e-6 {
                            Stat(label: "NUDGE", value: formatShift(sh), color: Theme.loop)
                        }
                    }
                    if let key = song?.key {
                        Stat(label: "KEY", value: key + (song?.camelot.map { "  " + $0 } ?? ""), color: Theme.bass)
                    }
                    if let g = song?.grid {
                        Stat(label: "BARS", value: "\(g.fullBars)", color: Theme.dim)
                    }
                    if let d = song?.duration {
                        Stat(label: "TIME", value: formatTime(d).components(separatedBy: ".")[0], color: Theme.dim)
                    }
                    if let e = song?.error {
                        Text(e).font(.system(size: 10.5)).foregroundColor(.orange).lineLimit(1)
                    }
                }
            }
            Spacer()
        }
        // EDIT / EXPORT sits in the middle of the top bar.
        .overlay(alignment: .center) { ModeSwitch() }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

struct Stat: View {
    let label: String
    let value: String
    let color: Color
    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 9, weight: .bold)).foregroundColor(Theme.dim)
            Text(value).font(Theme.mono(12, .semibold)).foregroundColor(color)
        }
    }
}

struct Segmented<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let label: (T) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { o in
                Text(label(o))
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(o == selection ? .black : Theme.dim)
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 5).fill(o == selection ? Theme.text : Color.clear))
                    .contentShape(Rectangle())
                    .onTapGesture { selection = o }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
    }
}

// MARK: - Lane headers (mixer)

struct LaneHeaders: View {
    @EnvironmentObject var session: Session
    @ObservedObject var clock: PlayClock

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("STEMS").font(.system(size: 9, weight: .bold)).foregroundColor(Theme.dim)
                Spacer()
                Text("EXPORT").font(.system(size: 9, weight: .bold)).foregroundColor(Theme.dim)
            }
            .padding(.horizontal, 12)
            .frame(height: rulerHeight)
            .background(Theme.panel2)
            ForEach(session.lanes) { lane in
                LaneHeader(lane: lane, level: lane.stems.compactMap { clock.levels[$0] }.reduce(0, +))
                    .frame(maxHeight: .infinity)
                    .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .top)
            }
        }
        .overlay(Rectangle().fill(Theme.line).frame(width: 1), alignment: .trailing)
    }
}

struct LaneHeader: View {
    @EnvironmentObject var session: Session
    let lane: Lane
    let level: Float

    var body: some View {
        let st = session.state(lane)
        let audible = session.isAudible(lane)
        HStack(spacing: 0) {
            Rectangle().fill(lane.color.opacity(audible ? 1 : 0.3)).frame(width: 4)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    Text(lane.title).font(.system(size: 11.5, weight: .heavy)).foregroundColor(audible ? Theme.text : Theme.dim)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    SmallToggle(text: "M", on: st.mute, color: Color(red: 1, green: 0.35, blue: 0.3)) {
                        session.setState(lane) { $0.mute.toggle() }
                    }
                    .help("Mute")
                    SmallToggle(text: "S", on: st.solo, color: Theme.loop) {
                        session.setState(lane) { $0.solo.toggle() }
                    }
                    .help("Solo")
                    SmallToggle(systemImage: "arrow.down.to.line", on: st.export, color: lane.color) {
                        // Hear what you export: off = muted, on = unmuted. M still works on its own.
                        session.setState(lane) { $0.export.toggle(); $0.mute = !$0.export }
                    }
                    .help("Include this lane in the export. Turning it off also mutes it (M brings it back to listen).")
                }
                Fader(value: Binding(get: { Double(st.gain) }, set: { v in session.setState(lane) { $0.gain = Float(v) } }),
                      color: lane.color, level: audible ? level : 0)
                    .frame(height: 16)
            }
            .padding(.horizontal, 10)
        }
    }
}

struct SmallToggle: View {
    var text: String? = nil
    var systemImage: String? = nil
    let on: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 9.5, weight: .bold)) }
                else { Text(text ?? "").font(.system(size: 10, weight: .heavy)) }
            }
            .foregroundColor(on ? .black : Theme.dim)
            .frame(width: 21, height: 19)
            .background(RoundedRectangle(cornerRadius: 4).fill(on ? color : Theme.panel2))
        }
        .buttonStyle(.plain)
    }
}

/// Horizontal fader with a level meter behind it. Double-click resets to 0 dB.
struct Fader: View {
    @Binding var value: Double
    let color: Color
    let level: Float

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let meter = CGFloat(min(1, sqrt(Double(level)) * 1.35))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.35))
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [color.opacity(0.35), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: w * meter)
                    .animation(.linear(duration: 0.05), value: meter)
                    .padding(.vertical, 5)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.text)
                    .frame(width: 6, height: g.size.height)
                    .offset(x: CGFloat(value) * (w - 6))
                    .shadow(color: .black.opacity(0.5), radius: 1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                value = Double(max(0, min(1, (v.location.x - 3) / (w - 6))))
            })
            .onTapGesture(count: 2) { value = 1 }
        }
        .help(value > 0 ? String(format: "%.1f dB", 20 * log10(value)) : "-∞ dB")
    }
}


/// Edit tools, floating over the lanes while something is selected or a lane is edited.
private struct RegionToolbar: View {
    @EnvironmentObject var session: Session
    var body: some View {
        HStack(spacing: 4) {
            Text(session.selected.isEmpty
                 ? (session.workMode == .edit ? "drag = select · click inside = cut" : "drag on a lane = export region")
                 : "\(session.selected.count) selected")
                .font(.system(size: 10, weight: .bold)).foregroundColor(Theme.dim).padding(.horizontal, 6)
            Button("DUPLICATE") { session.duplicateSelected() }
                .buttonStyle(PillButtonStyle(small: true)).help("Copy right after (⌘D), or ⌥-drag")
                .disabled(session.selected.isEmpty)
            Button("DELETE") { session.deleteSelected() }
                .buttonStyle(PillButtonStyle(color: Color(red: 1, green: 0.35, blue: 0.3), small: true)).help("⌫ — a deleted piece goes silent")
                .disabled(session.selected.isEmpty)
            Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(PillButtonStyle(small: true)).help("Undo (⌘Z)")
            Button("ORIGINAL") { session.resetEdits() }
                .buttonStyle(PillButtonStyle(color: .orange, small: true))
                .help("Back to the unedited audio on every lane (undo with ⌘Z)")
                .disabled(session.clips.isEmpty)
        }
        .padding(5)
        .background(Capsule().fill(Color.black.opacity(0.8)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
    }
}

/// EDIT (cut and rearrange) or EXPORT (mark regions to save).
private struct ModeSwitch: View {
    @EnvironmentObject var session: Session
    var body: some View {
        HStack(spacing: 2) {
            item(.edit, "scissors", "EDIT", Theme.active)
            item(.export, "square.and.arrow.down", "EXPORT", Theme.active)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
        .help("EDIT: drag = select, click inside = cut, then move / ⌘D / ⌫ the pieces.  EXPORT: drag = regions to export.  (E)")
    }

    private func item(_ m: Session.WorkMode, _ icon: String, _ label: String, _ color: Color) -> some View {
        let on = session.workMode == m
        return HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold))
            Text(label).font(.system(size: 11.5, weight: .heavy)).tracking(0.6)
        }
        .foregroundColor(on ? .white : Theme.dim)
        .padding(.horizontal, 16).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(on ? color : Color.clear)
                        .shadow(color: on ? color.opacity(0.9) : .clear, radius: 8))
        .animation(.easeOut(duration: 0.15), value: on)
        .contentShape(Rectangle())
        .onTapGesture { session.workMode = m }
    }
}
