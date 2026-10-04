import SwiftUI
import AppKit

/// Bottom deck: transport, loop, grid fixes and export, side by side.
struct ControlDeck: View {
    @EnvironmentObject var session: Session
    @ObservedObject var clock: PlayClock

    var body: some View {
        // The cards share the full width; each grows from its own natural size.
        // Grid on the left, transport in the very middle, stems and export (the output) on the right.
        // Both sides get the same width, so the transport stays centred.
        let row = HStack(alignment: .top, spacing: 10) {
            GridCard().frame(maxWidth: .infinity)
            TransportCard(clock: clock).fixedSize(horizontal: true, vertical: false)
            HStack(alignment: .top, spacing: 10) {
                StemsCard().frame(maxWidth: .infinity)
                ExportCard().frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
        }
        .fixedSize(horizontal: false, vertical: true)
        // Scrolls sideways only if the window is narrower than the deck.
        ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) { row }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Card<Content: View>: View {
    let title: String
    var accent: Color = Theme.dim
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 9.5, weight: .heavy)).tracking(1.2).foregroundColor(accent).fixedSize()
            content
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
    }
}

// MARK: Transport

struct TransportCard: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var library: Library
    @ObservedObject var clock: PlayClock

    var body: some View {
        let player = session.player
        Card(title: "TRANSPORT") {
            HStack(spacing: 10) {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.black)
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(player.isPlaying ? Theme.loop : Theme.text))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .help("Play / pause (space)")
                VStack(alignment: .leading, spacing: 3) {
                    Text(formatTime(clock.position)).font(Theme.mono(16, .semibold)).fixedSize()
                    if let g = library.selected?.grid {
                        let p = g.position(clock.position)
                        Text("BAR \(p.bar) · \(p.beat)").font(Theme.mono(10.5, .bold)).foregroundColor(Theme.accent).fixedSize()
                    }
                    HStack(spacing: 4) {
                        Button {
                            if let r = session.loopRange, session.loopEnabled { player.seek(max(0, r.lowerBound)); session.revealLoop() }
                            else { session.goToStart() }
                        } label: {
                            Image(systemName: "backward.end.fill")
                        }
                        .buttonStyle(PillButtonStyle(small: true))
                        .help("Back to the loop start / song start (Enter = very start)")
                        Button { session.follow.toggle() } label: { Text("FOLLOW") }
                            .buttonStyle(PillButtonStyle(color: Theme.accent, active: session.follow, small: true))
                            .help("The view pages along with the playhead")
                        Button { session.zoomToFit() } label: { Image(systemName: "arrow.left.and.right") }
                            .buttonStyle(PillButtonStyle(small: true))
                            .help("Show the whole song")
                        Button { session.loopEnabled.toggle() } label: {
                            HStack(spacing: 3) { Image(systemName: "repeat"); Text("LOOP") }
                        }
                        .buttonStyle(PillButtonStyle(color: Theme.loop, active: session.loopEnabled && session.loop != nil, small: true))
                        .keyboardShortcut("l", modifiers: [])
                        .disabled(session.loop == nil)
                        .modifier(DisabledDim())
                        .help("Loop on/off (L). Draw the loop in the ruler; double-click it there to remove it.")
                        Button { session.clickOn.toggle() } label: {
                            HStack(spacing: 3) { Image(systemName: "metronome.fill"); Text("CLICK") }
                        }
                        .buttonStyle(PillButtonStyle(color: Theme.loop, active: session.clickOn, small: true))
                        .keyboardShortcut("k", modifiers: [])
                        .help("Metronome on the beat grid, higher click on the 1 (K)")
                    }
                }
            }
        }
    }
}

// MARK: Grid

struct GridCard: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var library: Library
    @State private var bpmText = ""
    @FocusState private var bpmFocused: Bool

    var body: some View {
        let g = library.selected?.grid
        Card(title: "BEAT GRID", accent: Theme.accent) {
            HStack(spacing: 3) {
                TextField("BPM", text: $bpmText)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(12, .semibold))
                    .foregroundColor(Theme.accent)
                    .multilineTextAlignment(.center)
                    .frame(width: 66, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
                    .focused($bpmFocused)
                    .onSubmit { commitBPM() }
                    .help("Export tempo: loops are stretched to exactly this BPM")
                Button("×2") { session.scaleBPM(2) }.buttonStyle(PillButtonStyle(small: true))
                Button("÷2") { session.scaleBPM(0.5) }.buttonStyle(PillButtonStyle(small: true))
                Button { session.autoWarp() } label: {
                    HStack(spacing: 3) { Image(systemName: "wand.and.stars"); Text("AUTO WARP") }
                }
                .buttonStyle(PillButtonStyle(color: Theme.instrumental, small: true))
                .help("Follow the hits from the CUE point and pin every bar to its real downbeat")
                Button("RESET") { session.resetGrid() }
                    .buttonStyle(PillButtonStyle(color: .orange, small: true))
                    .help("Back to the detected CUE point and tempo, then AUTO WARP")
            }
            HStack(spacing: 3) {
                Text("NUDGE").font(.system(size: 9, weight: .heavy)).foregroundColor(Theme.dim).fixedSize()
                Button { session.nudge(-session.nudgeStep) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(PillButtonStyle(color: Theme.loop, small: true))
                    .keyboardShortcut("[", modifiers: [])
                    .help("Move the music earlier against the grid, i.e. the CUE point later ([)")
                Button { session.nudge(session.nudgeStep) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(PillButtonStyle(color: Theme.loop, small: true))
                    .keyboardShortcut("]", modifiers: [])
                    .help("Move the music later against the grid, i.e. the CUE point earlier (])")
                ForEach([(0.5, "½ BEAT"), (1.0, "1 BEAT"), (2.0, "½ BAR"), (4.0, "1 BAR")], id: \.0) { step, label in
                    Button(label) { session.nudgeStep = step }
                        .buttonStyle(PillButtonStyle(color: Theme.loop, active: session.nudgeStep == step, small: true))
                }
                let sh = library.selected?.contentShift ?? 0
                Button(abs(sh) > 1e-9 ? formatShift(sh) : "0") { session.resetNudge() }
                    .buttonStyle(PillButtonStyle(color: Theme.loop, small: true))
                    .help("Total nudge — click to reset")
            }
        }
        .disabled(g == nil)
        .onAppear { syncText() }
        .onChange(of: session.outputBPM) { _, _ in if !bpmFocused { syncText() } }
        .onChange(of: library.selectedID) { _, _ in syncText() }
        .onChange(of: bpmFocused) { _, f in if !f { commitBPM() } }
    }

    private func syncText() {
        bpmText = session.outputBPM.map { String(format: "%.2f", $0) } ?? ""
    }

    private func commitBPM() {
        let v = Double(bpmText.replacingOccurrences(of: ",", with: "."))
        if let v, v >= 40, v <= 250, abs(v - (session.outputBPM ?? 0)) > 0.0001 { session.setBPM(v) }
        syncText()
    }
}

// MARK: Stems

/// How the song is shown: one mix lane, or the separated stems; plus quick solo sets.
struct StemsCard: View {
    @EnvironmentObject var session: Session

    var body: some View {
        Card(title: "STEMS", accent: Theme.instrumental) {
            Segmented(options: StemMode.allCases, selection: $session.mode) { $0.label }
                .help("MIX: the whole song as one waveform. 2 / 4 STEMS: the separated lanes.")
            HStack(spacing: 3) {
                Button("ACAPELLA") { session.soloOnly(["vocals"]) }
                    .buttonStyle(PillButtonStyle(color: Theme.vocals, small: true))
                    .help("Vocals only")
                Button("INSTR.") {
                    if session.mode == .two { session.soloOnly(["instrumental"]) } else { session.soloOnly(["drums", "bass", "other"]) }
                }
                .buttonStyle(PillButtonStyle(color: Theme.instrumental, small: true))
                .help("Everything but the vocals")
                Button("ALL") { session.clearSoloMute() }
                    .buttonStyle(PillButtonStyle(color: Theme.text, small: true))
                    .help("Every lane back on")
            }
            .disabled(session.mode == .mix)
            .modifier(DisabledDim())
        }
    }
}

// MARK: Export

struct ExportCard: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var library: Library

    var body: some View {
        let song = library.selected
        let lanes = session.exportLanes.map(\.fileTag).joined(separator: session.selectedMix ? "+" : ", ")
        Card(title: "EXPORT", accent: Theme.bass) {
            HStack(spacing: 3) {
                kindButton(.full, "FULL", "doc.on.doc", "Every marked lane as it is: the whole file, original tempo, no edits.")
                kindButton(.cue, "FROM CUE", "flag.fill", "Every marked lane from the CUE (bar 1) to the end, on the export tempo — stack them in a DAW from bar 1.")
                Button("SEL. MIX") { session.selectedMix.toggle() }
                    .buttonStyle(PillButtonStyle(color: Theme.bass, active: session.selectedMix, small: true))
                    .help("SELECTED MIX: FULL, FROM CUE and LOOP put the marked lanes into one file (\(lanes.isEmpty ? "none marked" : lanes)), following the faders.")
            }
            HStack(spacing: 3) {
                kindButton(.loop, session.loop.map { "LOOP \($0.startBar)–\($0.endBar - 1)" } ?? "LOOP", "repeat",
                           "Every marked lane cut to the loop, bar-exact, on the export tempo, as loops (⌘E).")
                    .keyboardShortcut("e", modifiers: .command)
                kindButton(.regions, "REGIONS \(session.regionsToExport.count)", "square.stack.3d.down.forward.fill",
                           "Every export region on the marked lanes, each in its own file, as loops (⇧⌘E). Draw them in EXPORT mode.")
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("FADE \(Int(session.fadeMs))ms") { session.fadeOn.toggle() }
                    .buttonStyle(PillButtonStyle(color: Theme.bass, active: session.fadeOn, small: true))
                    .help("Anti-click fade at both ends (right-click for length)")
                    .contextMenu {
                        ForEach([2.0, 3, 5, 10], id: \.self) { ms in Button("\(Int(ms)) ms") { session.fadeMs = ms } }
                    }
            }
        }
        .help(song.map(formatLabel) ?? "")
        .overlay(alignment: .topTrailing) {
            if session.exporting { ProgressView().controlSize(.mini).padding(10) }
        }
    }

    private func kindButton(_ kind: Session.ExportKind, _ label: String, _ icon: String, _ help: String) -> some View {
        Button { session.export(kind) } label: {
            HStack(spacing: 4) { Image(systemName: icon).font(.system(size: 9.5, weight: .bold)); Text(label) }
        }
        .buttonStyle(PillButtonStyle(color: Theme.bass, filled: true, small: true))
        .disabled(!session.canExport(kind))
        .modifier(DisabledDim())
        .help(help)
    }

    private func formatLabel(_ s: Song) -> String {
        let ext = Exporter.outputExt(forSource: s.srcExt).uppercased()
        let bits = s.srcFloat ? "\(s.srcBits)f" : "\(s.srcBits)"
        return "Files: \(ext) \(bits)-bit \(String(format: "%g", s.srcSampleRate / 1000)) kHz, like the original"
    }
}

// MARK: Toast

struct ToastView: View {
    @EnvironmentObject var session: Session

    var body: some View {
        if let t = session.toast {
            HStack(spacing: 12) {
                Image(systemName: t.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundColor(t.isError ? .orange : Theme.bass)
                Text(t.text).font(.system(size: 12.5, weight: .semibold))
                if !t.files.isEmpty {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(t.files) }
                        .buttonStyle(PillButtonStyle(color: Theme.bass, small: true))
                }
                Button { session.toast = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundColor(Theme.dim)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(Capsule().fill(Theme.panel2).shadow(color: .black.opacity(0.5), radius: 12, y: 4))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: t) {
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                if session.toast == t { withAnimation { session.toast = nil } }
            }
        }
    }
}
