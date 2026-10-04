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
    @Published private(set) var pythonProblem: String?

    let root: URL
    private var running: Process?
    private var python: String?

    private init() {
        root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/STEMEKI")
        try? FileManager.default.createDirectory(at: songsDir, withIntermediateDirectories: true)
        load()
        // An interrupted job starts over.
        for i in songs.indices where songs[i].state == .separating || songs[i].state == .analyzing {
            songs[i].state = .queued
        }
        python = PythonRunner.findPython()
        if python == nil {
            pythonProblem = "No Python with Demucs found. Install it: pip install demucs librosa soundfile"
        }
        selectedID = songs.first(where: { $0.isReady })?.id
        processNext()
    }

    var songsDir: URL { root.appendingPathComponent("Songs") }
    var loopsDir: URL { root.appendingPathComponent("Loops") }
    private var libraryFile: URL { root.appendingPathComponent("library.json") }

    func stemsDir(_ song: Song) -> URL { songsDir.appendingPathComponent(song.id.uuidString) }

    var selected: Song? { songs.first { $0.id == selectedID } }

    // MARK: Persistence

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
            if var r = songs[i].regions { for k in r.indices { r[k].start += shift }; songs[i].regions = r }
            if var c = songs[i].clips { for k in c.indices { c[k].start += shift; c[k].src += shift }; songs[i].clips = c }
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

    func revealStems(_ song: Song) {
        NSWorkspace.shared.activateFileViewerSelecting([stemsDir(song)])
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
        running = PythonRunner.run(python: python, script: "separate", args: [song.sourcePath, tmp.path]) { [weak self] line in
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

/// Runs the bundled Python scripts with the Demucs-capable interpreter.
enum PythonRunner {
    static func findPython() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "\(home)/.pyenv/versions/3.10.13/bin/python3",
        ]
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: "\(home)/.pyenv/versions") {
            candidates += versions.sorted().reversed().map { "\(home)/.pyenv/versions/\($0)/bin/python3" }
        }
        candidates += ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
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

    static func lastError(_ log: String) -> String {
        let lines = log.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let json = lines.last(where: { $0.hasPrefix("{") }), json.contains("\"error\"") { return json }
        return lines.last.map { String($0.prefix(240)) } ?? "Unknown error"
    }
}

/// Thread-safe collector for a child process's output.
private final class LogBuffer: @unchecked Sendable {
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
