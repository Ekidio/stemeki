import Foundation
import CryptoKit
import SwiftUI

/// STEMEKI's own separation engine: a private Python with Demucs, set up by one click
/// in ~/Library/Application Support/STEMEKI/Engine, for Macs without a Python of their own.
enum Engine {
    static let pythonURL = URL(string: "https://github.com/astral-sh/python-build-standalone/releases/download/20250317/cpython-3.10.16+20250317-aarch64-apple-darwin-install_only.tar.gz")!
    static let pythonSHA256 = "e99f8457d9c79592c036489c5cfa78df76e4762d170665e499833e045d82608f"
    static let modelURL = URL(string: "https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/955717e8-8726e21a.th")!
    static let modelFile = "955717e8-8726e21a.th"
    /// torch.hub checks the file against this prefix of its SHA-256.
    static let modelHashPrefix = "8726e21a"
    /// Native packages must come as ready-made wheels: no compiler on the user's Mac.
    static let binaryOnly = "torch,torchaudio,numpy,scipy,numba,llvmlite,soundfile,lameenc,scikit-learn,soxr,msgpack,pyyaml,cffi"

    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("STEMEKI/Engine")
    }
    static var python: URL { dir.appendingPathComponent("python/bin/python3") }
    static var torchHome: URL { dir.appendingPathComponent("torch") }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: python.path)
            && FileManager.default.fileExists(atPath: torchHome.appendingPathComponent("hub/checkpoints/\(modelFile)").path)
    }

    static func owns(python path: String) -> Bool { path.hasPrefix(dir.path + "/") }
}

/// Downloads and sets up the engine, step by step, with progress for the setup screen.
@MainActor
final class EngineInstaller: ObservableObject {
    static let shared = EngineInstaller()

    enum Phase: Equatable { case idle, working, failed(String), done }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var step = ""
    @Published private(set) var detail = ""
    @Published private(set) var fraction = 0.0

    private var task: Task<Void, Never>?

    func start(onDone: @escaping @MainActor (String) -> Void) {
        guard phase != .working else { return }
        phase = .working
        fraction = 0
        task = Task {
            do {
                try await install()
                phase = .done
                onDone(Engine.python.path)
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func install() async throws {
        let fm = FileManager.default
        let partial = Engine.dir.deletingLastPathComponent().appendingPathComponent("Engine.partial")
        try? fm.removeItem(at: partial)
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)

        // Room for the download and the unpacked engine (about 1 GB).
        if let free = try? partial.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < 2_000_000_000 {
            throw EngineError("Not enough free disk space: the engine needs about 2 GB while installing.")
        }

        // 1. Python.
        step = "STEP 1 / 4 · Downloading Python"
        let archive = partial.appendingPathComponent("python.tar.gz")
        try await Downloader.fetch(Engine.pythonURL, to: archive) { [weak self] f, got, total in
            self?.fraction = 0.08 * f
            self?.detail = Self.megabytes(got, total)
        }
        guard try Self.sha256(archive) == Engine.pythonSHA256 else {
            throw EngineError("The Python download is damaged (checksum mismatch). Please try again.")
        }
        detail = "Unpacking…"
        try await Self.run("/usr/bin/tar", ["-xzf", archive.path, "-C", partial.path])
        try? fm.removeItem(at: archive)
        _ = try? await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", partial.path])
        let python = partial.appendingPathComponent("python/bin/python3")

        // 2. Demucs and friends, the exact versions STEMEKI is tested with.
        step = "STEP 2 / 4 · Installing Demucs (the AI)"
        fraction = 0.1
        guard let requirements = Bundle.main.url(forResource: "engine-requirements", withExtension: "txt") else {
            throw EngineError("Missing engine-requirements.txt in the app.")
        }
        let total = Double((try? String(contentsOf: requirements, encoding: .utf8))?
            .split(separator: "\n").filter { $0.contains("==") }.count ?? 48)
        var collected = 0.0
        try await Self.run(python.path, ["-m", "pip", "install", "--no-cache-dir", "--prefer-binary",
                                         "--only-binary=\(Engine.binaryOnly)", "--disable-pip-version-check",
                                         "--no-warn-script-location", "-r", requirements.path],
                           env: ["PIP_NO_INPUT": "1"]) { [weak self] line in
            guard let self else { return }
            if line.hasPrefix("Collecting ") {
                collected += 1
                self.detail = String(line.dropFirst(11)).components(separatedBy: " ").first ?? ""
                self.fraction = 0.1 + 0.55 * min(1, collected / total)
            } else if line.hasPrefix("Installing collected packages") {
                self.detail = "Putting it all together…"
                self.fraction = 0.7
            }
        }

        // 3. The trained model.
        step = "STEP 3 / 4 · Downloading the separation model"
        let checkpoints = partial.appendingPathComponent("torch/hub/checkpoints")
        try fm.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        let model = checkpoints.appendingPathComponent(Engine.modelFile)
        try await Downloader.fetch(Engine.modelURL, to: model) { [weak self] f, got, total in
            self?.fraction = 0.72 + 0.2 * f
            self?.detail = Self.megabytes(got, total)
        }
        guard try Self.sha256(model).hasPrefix(Engine.modelHashPrefix) else {
            throw EngineError("The model download is damaged (checksum mismatch). Please try again.")
        }

        // 4. Does it all load?
        step = "STEP 4 / 4 · Testing the engine"
        detail = "Loading the AI once…"
        fraction = 0.94
        try await Self.run(python.path, ["-c", "import demucs, librosa, soundfile, torch; "
                                         + "from demucs.pretrained import get_model; get_model('htdemucs')"],
                           env: ["TORCH_HOME": partial.appendingPathComponent("torch").path])

        try? fm.removeItem(at: Engine.dir)
        try fm.moveItem(at: partial, to: Engine.dir)
        fraction = 1
        detail = "Ready"
    }

    // MARK: Helpers

    nonisolated static func megabytes(_ got: Int64, _ total: Int64) -> String {
        let g = Double(got) / 1_000_000
        return total > 0 ? String(format: "%.0f of %.0f MB", g, Double(total) / 1_000_000) : String(format: "%.0f MB", g)
    }

    nonisolated static func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Runs a tool; stdout lines go to `onLine`, a failure throws with the end of its output.
    @discardableResult
    static func run(_ tool: String, _ args: [String], env extra: [String: String] = [:],
                    onLine: (@MainActor (String) -> Void)? = nil) async throws -> Int32 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PYTHONUNBUFFERED"] = "1"
            for (k, v) in extra { env[k] = v }
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            let log = LogBuffer()
            out.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
                for line in log.appendOut(s) {
                    if let onLine { DispatchQueue.main.async { MainActor.assumeIsolated { onLine(line) } } }
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
                if let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) { _ = log.appendOut(s) }
                if let s = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) { log.appendErr(s) }
                if proc.terminationStatus == 0 {
                    cont.resume(returning: 0)
                } else {
                    let tail = log.all.split(separator: "\n").suffix(3).joined(separator: "\n")
                    cont.resume(throwing: EngineError(tail.isEmpty ? "\(tool) failed" : tail))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}

struct EngineError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// A file download with progress.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let dest: URL
    private let progress: @MainActor (Double, Int64, Int64) -> Void
    private var cont: CheckedContinuation<Void, Error>?
    private var lastReport = Date.distantPast

    private init(dest: URL, progress: @escaping @MainActor (Double, Int64, Int64) -> Void) {
        self.dest = dest
        self.progress = progress
    }

    static func fetch(_ url: URL, to dest: URL,
                      progress: @escaping @MainActor (Double, Int64, Int64) -> Void) async throws {
        let d = Downloader(dest: dest, progress: progress)
        let session = URLSession(configuration: .default, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            d.cont = c
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten got: Int64, totalBytesExpectedToWrite total: Int64) {
        guard Date().timeIntervalSince(lastReport) > 0.1 else { return }
        lastReport = Date()
        let f = total > 0 ? Double(got) / Double(total) : 0
        let progress = progress
        DispatchQueue.main.async { MainActor.assumeIsolated { progress(f, got, total) } }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            cont?.resume(throwing: EngineError("Download failed (HTTP \(http.statusCode))."))
            cont = nil
            return
        }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            cont?.resume()
        } catch {
            cont?.resume(throwing: error)
        }
        cont = nil
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            cont?.resume(throwing: EngineError("Download failed: \(error.localizedDescription) Check the internet connection and try again."))
            cont = nil
        }
    }
}

// MARK: - Setup screen

/// Shown instead of the song area until the engine is there.
struct EngineSetupView: View {
    @EnvironmentObject var library: Library
    @ObservedObject var installer = EngineInstaller.shared

    var body: some View {
        VStack(spacing: 18) {
            StemekiLogo(height: 44)
            Text("ONE-TIME SETUP").font(.system(size: 11, weight: .heavy)).tracking(3).foregroundColor(Theme.dim)
            Text("STEMEKI needs its AI engine to split songs into stems.")
                .font(.system(size: 15, weight: .semibold))
            Text("One click installs everything: no Terminal, no Python knowledge needed.\nAbout 300 MB download, 1 GB on disk. It runs on your Mac, your music never leaves it.")
                .font(.system(size: 12)).foregroundColor(Theme.dim)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)

            switch installer.phase {
            case .working:
                VStack(alignment: .leading, spacing: 8) {
                    Text(installer.step).font(.system(size: 11, weight: .heavy)).tracking(1).foregroundColor(Theme.accent)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            Capsule().fill(LinearGradient(colors: [Theme.vocals, Theme.drums, Theme.bass, Theme.other],
                                                          startPoint: .leading, endPoint: .trailing))
                                .frame(width: g.size.width * CGFloat(installer.fraction))
                        }
                    }
                    .frame(height: 6)
                    HStack {
                        Text(installer.detail).font(Theme.mono(10.5)).foregroundColor(Theme.dim).lineLimit(1)
                        Spacer()
                        Text("\(Int(installer.fraction * 100))%").font(Theme.mono(10.5)).foregroundColor(Theme.dim)
                    }
                    Text("This takes a few minutes. You can already add songs, they wait in the list.")
                        .font(.system(size: 10.5)).foregroundColor(Theme.dim)
                }
                .frame(width: 420)
            case .failed(let message):
                VStack(spacing: 10) {
                    Text(message).font(.system(size: 11)).foregroundColor(.orange)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
                    installButton("TRY AGAIN")
                }
                .frame(width: 420)
            case .idle, .done:
                installButton("INSTALL ENGINE")
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func installButton(_ title: String) -> some View {
        Button { library.installEngine() } label: {
            HStack(spacing: 8) { Image(systemName: "arrow.down.circle.fill"); Text(title) }
                .font(.system(size: 13, weight: .heavy)).tracking(1)
                .foregroundColor(.white)
                .padding(.horizontal, 22).frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.active))
                .shadow(color: Theme.active.opacity(0.6), radius: 10)
        }
        .buttonStyle(.plain)
    }
}
