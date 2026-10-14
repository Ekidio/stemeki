import AVFoundation

/// Videos (and audio formats macOS cannot open, like WebM, MKV, AVI, Opus): their first audio track becomes a
/// WAV in the song's folder, and from there the song is handled like any audio file.
/// Decoders, first that works: macOS itself (MP4, MOV, M4V…), the ffmpeg of the Mac (Homebrew), then PyAV
/// in the STEMEKI engine (installed into it the first time it is needed, about 50 MB).
enum MediaImport {
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "webm", "mkv", "avi", "mpg", "mpeg", "ts", "mts", "m2ts",
                                               "flv", "wmv", "3gp", "ogv", "opus", "wma", "weba", "mka"]
    /// The PyAV build the engine gets (Python 3.10 wheels for Apple Silicon, FFmpeg LGPL).
    static let pyav = "av==16.0.1"

    struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Writes the audio of `src` to `dst` (WAV). Blocking: call it off the main thread.
    static func extract(_ src: URL, to dst: URL, python: String?) throws {
        try? FileManager.default.removeItem(at: dst)
        if (try? native(src, dst)) != nil { return }
        if let ff = ffmpegPath, (try? ffmpeg(ff, src, dst)) != nil { return }
        guard let python else {
            throw ImportError(message: "This kind of file needs the STEMEKI engine (or ffmpeg) to read its audio.")
        }
        var r = runPython(python, src, dst)
        if r == "no-av" {
            // The engine gets the decoder the first time a video needs it.
            guard Engine.owns(python: python) else {
                throw ImportError(message: "To read this file, install ffmpeg (brew install ffmpeg) or STEMEKI's own engine.")
            }
            try installPyAV(python)
            r = runPython(python, src, dst)
        }
        if let r { throw ImportError(message: r == "no-av" ? "The audio decoder could not be installed." : r) }
    }

    // MARK: macOS (AVFoundation)

    static func native(_ src: URL, _ dst: URL) throws {
        let asset = AVURLAsset(url: src)
        guard let track = asset.tracks(withMediaType: .audio).first else { throw ImportError(message: "No audio track") }
        let reader = try AVAssetReader(asset: asset)
        let rate = (track.formatDescriptions.first.map { CMAudioFormatDescriptionGetStreamBasicDescription($0 as! CMAudioFormatDescription)?.pointee.mSampleRate ?? 44100 }) ?? 44100
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                                       AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                                       AVSampleRateKey: rate, AVNumberOfChannelsKey: 2]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        guard reader.startReading() else { throw ImportError(message: reader.error?.localizedDescription ?? "Could not read") }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: true) else {
            throw ImportError(message: "Audio format")
        }
        let file = try AVAudioFile(forWriting: dst, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        while let sb = output.copyNextSampleBuffer() {
            let frames = CMSampleBufferGetNumSamples(sb)
            guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { continue }
            buf.frameLength = AVAudioFrameCount(frames)
            let st = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList)
            guard st == noErr else { throw ImportError(message: "Could not decode the audio") }
            try file.write(from: buf)
        }
        guard reader.status == .completed, file.length > 0 else { throw ImportError(message: "Could not decode the audio") }
    }

    // MARK: ffmpeg of the Mac

    static var ffmpegPath: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func ffmpeg(_ ff: String, _ src: URL, _ dst: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ff)
        p.arguments = ["-v", "error", "-nostdin", "-y", "-i", src.path, "-map", "0:a:0", "-vn", "-ac", "2", "-c:a", "pcm_f32le", dst.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: dst.path) else { throw ImportError(message: "ffmpeg failed") }
    }

    // MARK: PyAV in the engine

    /// nil = done; otherwise the error ("no-av" when the decoder is missing).
    private static func runPython(_ python: String, _ src: URL, _ dst: URL) -> String? {
        guard let script = Bundle.main.url(forResource: "extract", withExtension: "py") else { return "Missing extract.py" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-I", script.path, src.path, dst.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return error.localizedDescription }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let line = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
        if p.terminationStatus == 0 { return nil }
        if let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let e = j["error"] as? String { return e }
        return "Could not read the audio of this file."
    }

    private static func installPyAV(_ python: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-m", "pip", "install", "--disable-pip-version-check", "--no-warn-script-location",
                       "--only-binary=:all:", pyav]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ImportError(message: "The audio decoder (PyAV) could not be installed: check the internet connection.") }
    }
}
