import Foundation
import AVFoundation
import AppKit

/// The song list, the stem folders on disk and the separation queue.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var songs: [Song] = []
    @Published var selectedID: UUID?
    @Published private(set) var progress: [UUID: Double] = [:]
    /// No Python with Demucs on this Mac: the setup screen offers STEMEKI's own engine.
    @Published private(set) var needsEngine = false
    /// Separated in this session and not yet analyzed: celebrated when they come out ready.
    private var freshlySeparated: Set<UUID> = []

    let root: URL
    private var running: Process?
    private var python: String?

    private init() {
        // Testing: STEMEKI_LIBRARY=<folder> keeps a test copy away from the real song list.
        if let test = ProcessInfo.processInfo.environment["STEMEKI_LIBRARY"] {
            root = URL(fileURLWithPath: test, isDirectory: true)
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/STEMEKI")
        }
        try? FileManager.default.createDirectory(at: songsDir, withIntermediateDirectories: true)
        startClean()
        load()
        // An interrupted job starts over.
        for i in songs.indices where songs[i].state == .separating || songs[i].state == .analyzing {
            songs[i].state = .queued
        }
        python = PythonRunner.findPython()
        needsEngine = python == nil
        selectedID = songs.first(where: { $0.isReady })?.id
        processNext()
    }

    var songsDir: URL { root.appendingPathComponent("Songs") }
    var loopsDir: URL { root.appendingPathComponent("Loops") }

    /// Where exports go: the folder chosen last time (the STEMEKI Loops folder at first).
    var exportFolder: URL {
        get {
            if let p = UserDefaults.standard.string(forKey: "exportFolder"),
               FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p, isDirectory: true) }
            return loopsDir
        }
        set { UserDefaults.standard.set(newValue.path, forKey: "exportFolder") }
    }

    /// Asks where to save, starting in the last export folder. nil = cancelled.
    func chooseExportFolder(title: String) -> URL? {
        try? FileManager.default.createDirectory(at: loopsDir, withIntermediateDirectories: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = exportFolder
        panel.prompt = "Export Here"
        panel.message = title
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        exportFolder = url
        return url
    }
    private var libraryFile: URL { root.appendingPathComponent("library.json") }

    func stemsDir(_ song: Song) -> URL { songsDir.appendingPathComponent(song.id.uuidString) }

    var selected: Song? { songs.first { $0.id == selectedID } }

    // MARK: Persistence

    /// Every launch starts with a clean slate: the previous session's songs leave the list and their
    /// stem folders go to the Trash (recoverable from there).
    private func startClean() {
        // A test library (STEMEKI_LIBRARY) keeps its songs.
        if ProcessInfo.processInfo.environment["STEMEKI_LIBRARY"] != nil { return }
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: songsDir, includingPropertiesForKeys: nil) {
            for item in items { try? fm.trashItem(at: item, resultingItemURL: nil) }
        }
        try? Data("[]".utf8).write(to: libraryFile, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: libraryFile) else { return }
        songs = (try? JSONDecoder().decode([Song].self, from: data)) ?? []
        // Older saves counted bars from the start of the file; move them to the CUE-based numbering
        // so every region, cut and loop stays on the same music. Existing CUEs are left alone.
        var changed = false
        for i in songs.indices where songs[i].cueBased != true {
            defer { songs[i].cueBased = true; songs[i].autoCued = songs[i].autoCued ?? (songs[i].autoWarped == true) }
            changed = true
            guard let bpm = songs[i].bpm, let dur = songs[i].duration else { continue }
            let pts = songs[i].beatMap ?? songs[i].downbeat.map { [BeatPoint(beat: 0, time: $0)] } ?? []
            guard !pts.isEmpty else { continue }
            let shift = Int(Grid.legacyFirstBarBeat(points: pts, bpm: bpm, duration: dur))
            guard shift != 0 else { continue }
            let st = shift * ticksPerBeat
            if var r = songs[i].regions { for k in r.indices { r[k].start += st }; songs[i].regions = r }
            if var c = songs[i].clips { for k in c.indices { c[k].start += st; c[k].src += st }; songs[i].clips = c }
            if let lb = songs[i].loopStartBar { songs[i].loopStartBar = lb + shift / 4 }
        }
        if changed { save() }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(songs) { try? data.write(to: libraryFile, options: .atomic) }
    }

    func update(_ id: UUID, _ change: (inout Song) -> Void) {
        guard let i = songs.firstIndex(where: { $0.id == id }) else { return }
        change(&songs[i])
        save()
    }

    // MARK: Adding and removing

    static let audioExtensions: Set<String> = ["wav", "aif", "aiff", "mp3", "m4a", "flac", "aac", "caf", "ogg"]

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose the songs to separate"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func add(_ urls: [URL]) {
        var firstNew: UUID?
        for url in urls {
            if url.pathExtension.lowercased() == Self.projectExtension {
                do { try openProject(url) } catch { projectAlert("Could not open “\(url.lastPathComponent)”", error) }
                continue
            }
            if url.hasDirectoryPath {
                let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                add(items.sorted { $0.lastPathComponent < $1.lastPathComponent })
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard Self.audioExtensions.contains(ext) else { continue }
            if let existing = songs.first(where: { $0.sourcePath == url.path }) {
                firstNew = firstNew ?? existing.id
                continue
            }
            guard let file = try? AVAudioFile(forReading: url) else { continue }
            let settings = file.fileFormat.settings
            let isPCM = (settings[AVFormatIDKey] as? UInt32) == kAudioFormatLinearPCM
            let bits = isPCM ? (settings[AVLinearPCMBitDepthKey] as? Int ?? 24)
                : (settings[AVEncoderBitDepthHintKey] as? Int ?? (ext == "flac" ? 24 : 24))
            let song = Song(title: url.deletingPathExtension().lastPathComponent,
                            sourcePath: url.path,
                            srcExt: ext,
                            srcSampleRate: file.fileFormat.sampleRate,
                            srcBits: bits,
                            srcFloat: isPCM && (settings[AVLinearPCMIsFloatKey] as? Bool ?? false),
                            srcChannels: Int(file.fileFormat.channelCount),
                            duration: Double(file.length) / file.fileFormat.sampleRate,
                            cueBased: true)
            songs.insert(song, at: 0)
            firstNew = firstNew ?? song.id
        }
        save()
        // Show the song just added: its waveform and the splitting animation come up right away.
        if let firstNew { selectedID = firstNew }
        processNext()
    }

    func remove(_ id: UUID) {
        guard let song = songs.first(where: { $0.id == id }) else { return }
        if song.state == .separating || song.state == .analyzing {
            running?.terminate()
            running = nil
        }
        // Into the Trash, not deleted for good.
        try? FileManager.default.trashItem(at: stemsDir(song), resultingItemURL: nil)
        songs.removeAll { $0.id == id }
        progress[id] = nil
        if selectedID == id { selectedID = songs.first(where: { $0.isReady })?.id }
        save()
        processNext()
    }

    func retry(_ id: UUID) {
        update(id) { $0.state = .queued; $0.error = nil }
        processNext()
    }

    /// Re-run only the beat/key analysis.
    func reanalyze(_ id: UUID) {
        update(id) { $0.state = .queued; $0.error = nil; $0.bpm = nil }
        processNext()
    }

    // MARK: Projects

    /// A song as it was last saved or opened (encoded), to tell unsaved changes.
    @Published private(set) var savedState: [UUID: Data] = [:]

    private func fingerprint(_ s: Song) -> Data? {
        var s = s
        s.state = .ready; s.error = nil; s.mixer = nil
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        return try? enc.encode(s)
    }

    /// Changed since it was saved; a never-saved song only once it has edits or regions.
    func isUnsaved(_ s: Song) -> Bool {
        guard s.isReady else { return false }
        if let saved = savedState[s.id] { return fingerprint(s) != saved }
        return s.clips != nil || !(s.regions ?? []).isEmpty
    }

    var unsavedSongs: [Song] { songs.filter(isUnsaved) }

    struct ProjectFile: Codable {
        var format = "STEMEKI project"
        var version = 1
        var app: String?
        var song: Song
        var mixer: [String: Session.LaneState]
    }

    static let projectExtension = "stemeki"

    /// Writes "<name>.stemeki": project.json and the stems (cloned on APFS, so it costs almost no space).
    func saveProject(_ id: UUID, mixer: [String: Session.LaneState], to url: URL) throws {
        guard var song = songs.first(where: { $0.id == id }), song.isReady else { throw ProjectError("The song is not ready yet.") }
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).saving")
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp.appendingPathComponent("Stems"), withIntermediateDirectories: true)
        for kind in StemKind.separated {
            try fm.copyItem(at: stemsDir(song).appendingPathComponent(kind.fileName),
                            to: tmp.appendingPathComponent("Stems").appendingPathComponent(kind.fileName))
        }
        song.projectPath = url.path
        var saved = song
        saved.mixer = nil
        let file = ProjectFile(app: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, song: saved, mixer: mixer)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(file).write(to: tmp.appendingPathComponent("project.json"), options: .atomic)
        if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: tmp) } else { try fm.moveItem(at: tmp, to: url) }
        update(id) { $0.projectPath = url.path }
        if let s = songs.first(where: { $0.id == id }) { savedState[id] = fingerprint(s) }
    }

    /// Opens a project: its stems come back, no separation needed. Returns the song's id.
    @discardableResult
    func openProject(_ url: URL) throws -> UUID {
        let fm = FileManager.default
        let data = try Data(contentsOf: url.appendingPathComponent("project.json"))
        let file = try JSONDecoder().decode(ProjectFile.self, from: data)
        // Already open (from this file): just show it.
        if let open = songs.first(where: { $0.projectPath == url.path }) {
            selectedID = open.id
            return open.id
        }
        var song = file.song
        // Always a new identity: the player must load it fresh, even if this song was open before.
        song.id = UUID()
        let dir = stemsDir(song)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for kind in StemKind.separated {
            let src = url.appendingPathComponent("Stems").appendingPathComponent(kind.fileName)
            guard fm.fileExists(atPath: src.path) else { throw ProjectError("The project is missing \(kind.fileName).") }
            try fm.copyItem(at: src, to: dir.appendingPathComponent(kind.fileName))
        }
        song.projectPath = url.path
        song.state = .ready
        song.error = nil
        song.mixer = file.mixer
        songs.insert(song, at: 0)
        save()
        savedState[song.id] = fingerprint(song)
        selectedID = song.id
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        return song.id
    }

    /// Opened once: the mixer settings go to the session, then they are no longer needed here.
    func takeMixer(_ id: UUID) -> [String: Session.LaneState]? {
        guard let m = songs.first(where: { $0.id == id })?.mixer else { return nil }
        if let i = songs.firstIndex(where: { $0.id == id }) { songs[i].mixer = nil }
        return m
    }

    func revealStems(_ song: Song) {
        NSWorkspace.shared.activateFileViewerSelecting([stemsDir(song)])
    }

    /// One click: download and set up the engine, then work through the waiting songs.
    func installEngine() {
        EngineInstaller.shared.start { [weak self] path in
            guard let self else { return }
            self.python = path
            self.needsEngine = false
            self.processNext()
        }
    }

    // MARK: Queue

    private func processNext() {
        guard running == nil, let python else { return }
        // Oldest first.
        guard let song = songs.last(where: { $0.state == .queued }) else { return }
        let dir = stemsDir(song)
        let haveStems = StemKind.separated.allSatisfy {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.fileName).path)
        }
        if haveStems { analyze(song, python: python) } else { separate(song, python: python) }
    }

    private func separate(_ song: Song, python: String) {
        let id = song.id
        guard FileManager.default.fileExists(atPath: song.sourcePath) else {
            update(id) { $0.state = .failed; $0.error = "The original file was not found" }
            processNext()
            return
        }
        update(id) { $0.state = .separating }
        progress[id] = 0
        let tmp = stemsDir(song).appendingPathComponent("tmp")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // Without ffmpeg, Demucs reads only WAV/AIFF/FLAC: macOS decodes the rest (MP3, M4A…) first.
        var input = song.sourcePath
        if !PythonRunner.hasFFmpeg,
           !["wav", "wave", "aif", "aiff", "flac"].contains(URL(fileURLWithPath: input).pathExtension.lowercased()) {
            let wav = tmp.appendingPathComponent("source.wav")
            do {
                try AudioDecode.toWAV(URL(fileURLWithPath: input), wav)
                input = wav.path
            } catch {
                update(id) { $0.state = .failed; $0.error = "Could not read this file: \(error.localizedDescription)" }
                progress[id] = nil
                processNext()
                return
            }
        }
        running = PythonRunner.run(python: python, script: "separate", args: [input, tmp.path]) { [weak self] line in
            if line.hasPrefix("PROGRESS "), let v = Double(line.dropFirst(9)) {
                self?.progress[id] = v * 0.9
            }
        } completion: { [weak self] status, log in
            guard let self else { return }
            self.running = nil
            let dir = self.stemsDir(song)
            if status == 0 {
                for kind in StemKind.separated {
                    let dst = dir.appendingPathComponent(kind.fileName)
                    try? FileManager.default.removeItem(at: dst)
                    try? FileManager.default.moveItem(at: tmp.appendingPathComponent(kind.fileName), to: dst)
                }
                try? FileManager.default.removeItem(at: tmp)
                self.freshlySeparated.insert(id)
                if let s = self.songs.first(where: { $0.id == id }) {
                    self.analyze(s, python: python)
                }
            } else {
                if self.songs.contains(where: { $0.id == id }) {
                    self.update(id) { $0.state = .failed; $0.error = PythonRunner.lastError(log) }
                }
                self.progress[id] = nil
                self.processNext()
            }
        }
    }

    private func analyze(_ song: Song, python: String) {
        let id = song.id
        update(id) { $0.state = .analyzing }
        progress[id] = 0.93
        running = PythonRunner.run(python: python, script: "analyze", args: [stemsDir(song).path]) { _ in
        } completion: { [weak self] status, log in
            guard let self else { return }
            self.running = nil
            self.progress[id] = nil
            guard self.songs.contains(where: { $0.id == id }) else { self.processNext(); return }
            let json = log.split(separator: "\n").last(where: { $0.hasPrefix("{") }).map(String.init) ?? ""
            guard status == 0, let data = json.data(using: .utf8),
                  let r = try? JSONDecoder().decode(AnalysisResult.self, from: data) else {
                self.update(id) { $0.state = .failed; $0.error = PythonRunner.lastError(log) }
                self.processNext()
                return
            }
            self.update(id) { s in
                s.duration = r.duration ?? s.duration
                s.drumStart = r.drumStart
                s.key = r.key
                s.camelot = r.camelot
                // Freshly prepared: open on the four coloured stems.
                if s.viewMode == nil { s.viewMode = .four }
                if let bpm = r.bpm, let db = r.downbeat {
                    s.bpm = bpm; s.downbeat = db
                    s.autoBpm = bpm; s.autoDownbeat = db
                    s.state = .ready
                    s.error = nil
                } else {
                    // No beat found: still usable, the grid can be set by hand.
                    s.bpm = 120; s.downbeat = 0
                    s.autoBpm = 120; s.autoDownbeat = 0
                    s.state = .ready
                    s.error = "No beat found, set the grid by hand"
                }
            }
            if self.selected?.isReady != true { self.selectedID = id }
            if self.freshlySeparated.remove(id) != nil { Celebrate.shared.songSeparated(id) }
            self.processNext()
        }
    }
}

private struct AnalysisResult: Decodable {
    var bpm: Double?
    var downbeat: Double?
    var drumStart: Double?
    var duration: Double?
    var key: String?
    var camelot: String?
    var error: String?
}

struct ProjectError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

@MainActor
func projectAlert(_ title: String, _ error: Error) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = error.localizedDescription
    a.alertStyle = .warning
    a.runModal()
}

/// Runs the bundled Python scripts with the Demucs-capable interpreter.
enum PythonRunner {
    /// Testing: STEMEKI_OWN_ENGINE=1 ignores every other Python (and ffmpeg), like on a fresh Mac.
    static let ownEngineOnly = ProcessInfo.processInfo.environment["STEMEKI_OWN_ENGINE"] == "1"

    static func findPython() -> String? {
        if ownEngineOnly { return Engine.isInstalled ? Engine.python.path : nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "\(home)/.pyenv/versions/3.10.13/bin/python3",
        ]
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: "\(home)/.pyenv/versions") {
            candidates += versions.sorted().reversed().map { "\(home)/.pyenv/versions/\($0)/bin/python3" }
        }
        candidates += ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        // STEMEKI's own engine (one-click setup) last: a working Python of the user's own comes first.
        if Engine.isInstalled { candidates.append(Engine.python.path) }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["-c", "import demucs, librosa, soundfile"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { continue }
            p.waitUntilExit()
            if p.terminationStatus == 0 { return path }
        }
        return nil
    }

    /// `onLine` gets stdout lines, `completion` the exit status and the whole output (stdout + stderr).
    @MainActor
    static func run(python: String, script: String, args: [String],
                    onLine: @escaping @MainActor (String) -> Void,
                    completion: @escaping @MainActor (Int32, String) -> Void) -> Process? {
        guard let scriptURL = Bundle.main.url(forResource: script, withExtension: "py") else {
            completion(-1, "Missing script: \(script).py")
            return nil
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [scriptURL.path] + args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        // The own engine keeps its model next to itself.
        if Engine.owns(python: python) { env["TORCH_HOME"] = Engine.torchHome.path }
        p.environment = env

        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let log = LogBuffer()

        out.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            for line in log.appendOut(s) {
                DispatchQueue.main.async { onLine(line) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            log.appendErr(s)
        }
        p.terminationHandler = { proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let rest = out.fileHandleForReading.readDataToEndOfFile()
            if let s = String(data: rest, encoding: .utf8) { _ = log.appendOut(s + "\n") }
            let status = proc.terminationStatus
            let text = log.all
            DispatchQueue.main.async { completion(status, text) }
        }
        do {
            try p.run()
        } catch {
            completion(-1, error.localizedDescription)
            return nil
        }
        return p
    }

    static var hasFFmpeg: Bool {
        !ownEngineOnly && ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func lastError(_ log: String) -> String {
        let lines = log.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let json = lines.last(where: { $0.hasPrefix("{") }), json.contains("\"error\"") { return json }
        return lines.last.map { String($0.prefix(240)) } ?? "Unknown error"
    }
}

/// Thread-safe collector for a child process's output.
final class LogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var partial = ""
    private var text = ""

    func appendOut(_ s: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        text += s
        partial += s
        var lines = partial.components(separatedBy: "\n")
        partial = lines.removeLast()
        return lines
    }

    func appendErr(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        text += s
    }

    var all: String {
        lock.lock(); defer { lock.unlock() }
        return text
    }
}

/// Decodes any file macOS can read (MP3, M4A, …) to a 32-bit float WAV at its own sample rate.
enum AudioDecode {
    static func toWAV(_ src: URL, _ dst: URL) throws {
        let input = try AVAudioFile(forReading: src)
        let format = input.processingFormat
        try? FileManager.default.removeItem(at: dst)
        let output = try AVAudioFile(forWriting: dst, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 16) else { return }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
    }
}
