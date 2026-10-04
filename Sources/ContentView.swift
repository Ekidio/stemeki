import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var session: Session
    @State private var dropping = false
    @State private var splash = true
    @AppStorage("introSeen") private var introSeen = false
    @State private var showIntro = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: 232)
                Rectangle().fill(Theme.line).frame(width: 1)
                Group {
                    if let song = library.selected, song.isReady {
                        EditorView(player: session.player)
                    } else if let song = library.selected {
                        ProcessingView(song: song)
                    } else {
                        EmptyStateView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // The control deck runs the full width of the window, under the song list too.
            if library.selected?.isReady == true {
                Rectangle().fill(Theme.line).frame(height: 1)
                ControlDeck(clock: session.player.clock)
                    .padding(12)
                    .background(Theme.panel.opacity(0.5))
            }
        }
        .background(Theme.bg)
        .foregroundColor(Theme.text)
        .overlay(dropping ? DropOverlay() : nil)
        .overlay { if showIntro { OnboardingView { introSeen = true; withAnimation { showIntro = false } }.transition(.opacity) } }
        .overlay { if splash { SplashView { splash = false; if !introSeen { withAnimation { showIntro = true } } } } }
        .onReceive(NotificationCenter.default.publisher(for: .showIntro)) { _ in withAnimation { showIntro = true } }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            loadURLs(providers) { library.add($0) }
            return true
        }
        .onChange(of: library.selectedID) { _, _ in session.open(library.selected) }
        .onChange(of: library.selected?.state) { _, _ in session.open(library.selected) }
        .onAppear {
            session.open(library.selected)
            // No text field should hold the keyboard at launch: space is play/pause.
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
        .preferredColorScheme(.dark)
    }
}

func loadURLs(_ providers: [NSItemProvider], _ done: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    let box = URLBox()
    for p in providers {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { box.append(url) }
            group.leave()
        }
    }
    group.notify(queue: .main) { MainActor.assumeIsolated { done(box.urls) } }
}

private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var urls: [URL] = []
    func append(_ u: URL) { lock.lock(); urls.append(u); lock.unlock() }
}

struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.accent.opacity(0.08)))
            .overlay(Text("Drop to add songs").font(.system(size: 20, weight: .semibold)).foregroundColor(Theme.accent))
            .padding(10)
            .allowsHitTesting(false)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var library: Library

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("STEM").font(.system(size: 21, weight: .black)).tracking(1.5)
                Text("EKI").font(.system(size: 21, weight: .black)).tracking(1.5).foregroundColor(Theme.loop)
                Spacer()
                Button { NotificationCenter.default.post(name: .showIntro, object: nil) } label: {
                    Image(systemName: "questionmark").font(.system(size: 12, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                }
                .buttonStyle(.plain)
                .help("Quick intro")
                Button { library.chooseFiles() } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                        .frame(width: 28, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                }
                .buttonStyle(.plain)
                .help("Add songs (⌘O)")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 2)
            Text("STEMS · LOOPS · REMIX")
                .font(.system(size: 9.5, weight: .heavy)).tracking(3.2)
                .foregroundColor(Theme.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            HStack(spacing: 4) {
                ForEach([Theme.vocals, Theme.drums, Theme.bass, Theme.other], id: \.self) { c in
                    Capsule().fill(c).frame(height: 3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            if let problem = library.pythonProblem {
                Text(problem).font(.system(size: 11)).foregroundColor(.orange)
                    .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(library.songs) { song in
                        SongRow(song: song, selected: song.id == library.selectedID,
                                progress: library.progress[song.id])
                            .onTapGesture { library.selectedID = song.id }
                            .contextMenu {
                                if song.isReady {
                                    Button("Show Stems in Finder") { library.revealStems(song) }
                                    Button("Re-analyze (BPM, grid, key)") { library.reanalyze(song.id) }
                                }
                                if song.state == .failed { Button("Retry") { library.retry(song.id) } }
                                Divider()
                                Button("Remove (stems to Trash)", role: .destructive) { library.remove(song.id) }
                            }
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)
        }
        .background(Theme.panel)
    }
}

struct SongRow: View {
    let song: Song
    let selected: Bool
    let progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(song.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            switch song.state {
            case .ready:
                HStack(spacing: 6) {
                    if let bpm = song.bpm { Tag(text: formatBPM(bpm) + " BPM", color: Theme.accent) }
                    if let key = song.key { Tag(text: key + (song.camelot.map { " · " + $0 } ?? ""), color: Theme.bass) }
                    Spacer()
                    if let d = song.duration { Text(formatTime(d).components(separatedBy: ".")[0]).font(Theme.mono(10)).foregroundColor(Theme.dim) }
                }
            case .queued:
                Text("Queued…").font(.system(size: 10.5)).foregroundColor(Theme.dim)
            case .separating, .analyzing:
                VStack(alignment: .leading, spacing: 4) {
                    Text(song.state == .separating ? "Separating \(Int((progress ?? 0) * 100))%" : "Analyzing beat and key…")
                        .font(.system(size: 10.5)).foregroundColor(Theme.accent)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            Capsule().fill(LinearGradient(colors: [Theme.vocals, Theme.drums, Theme.bass, Theme.other],
                                                          startPoint: .leading, endPoint: .trailing))
                                .frame(width: g.size.width * CGFloat(progress ?? 0))
                        }
                    }
                    .frame(height: 4)
                }
            case .failed:
                Text(song.error ?? "Error").font(.system(size: 10.5)).foregroundColor(.red).lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Theme.panel2 : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.white.opacity(0.08) : .clear))
        )
        .contentShape(Rectangle())
    }
}

struct Tag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(Theme.mono(9.5, .semibold)).foregroundColor(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.13)))
    }
}

// MARK: - Empty and processing states

struct EmptyStateView: View {
    @EnvironmentObject var library: Library
    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array([Theme.vocals, Theme.drums, Theme.bass, Theme.other].enumerated()), id: \.offset) { i, c in
                    RoundedRectangle(cornerRadius: 4).fill(c).frame(width: 14, height: CGFloat([46, 70, 34, 58][i]))
                }
            }
            Text("Drop songs here").font(.system(size: 22, weight: .bold))
            Text("WAV, AIFF, MP3, M4A or FLAC. STEMEKI splits them into\nvocals, drums, bass and instruments, and finds the bar grid.")
                .multilineTextAlignment(.center).font(.system(size: 13)).foregroundColor(Theme.dim)
            Button("Choose Songs…") { library.chooseFiles() }
                .buttonStyle(PillButtonStyle(color: Theme.accent, filled: true))
        }
    }
}

// MARK: - Buttons

struct PillButtonStyle: ButtonStyle {
    var color: Color = Theme.text
    var filled = false
    var active = false
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .fixedSize()
            .font(.system(size: small ? 10.5 : 11.5, weight: .bold))
            .foregroundColor(filled || active ? .black : color)
            .padding(.horizontal, small ? 7 : 11)
            .frame(minHeight: small ? 22 : 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(filled || active ? color : Theme.panel2)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(filled || active ? 0 : 0.07)))
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

struct DisabledDim: ViewModifier {
    @Environment(\.isEnabled) var enabled
    func body(content: Content) -> some View { content.opacity(enabled ? 1 : 0.35) }
}

extension Notification.Name {
    static let showIntro = Notification.Name("STEMEKIShowIntro")
}
