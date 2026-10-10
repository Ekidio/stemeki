import AVFoundation
import AppKit

/// DJ STEMS: one Native Instruments Stems file (.stem.mp4) that Traktor, Mixxx and other Stems-aware DJ software
/// and hardware open with four decks of stems, while any music player plays it as a normal song.
/// Layout: track 1 the full mix (the only enabled track), tracks 2–5 drums, bass, other, vocals (disabled),
/// AAC at 44.1 kHz, and the stem names, colours and mastering settings as JSON in moov/udta/stem.
enum StemFile {
    struct Stem { let url: URL; let name: String; let color: String }

    struct Tags {
        var title: String
        var artist: String?
        var bpm: Int?
        var artwork: Data?      // JPEG or PNG
    }

    /// `master` and the four `stems` are WAV files of the same length; writes `out`.
    static func write(master: URL, stems: [Stem], tags: Tags, to out: URL) throws {
        precondition(stems.count == 4)
        try? FileManager.default.removeItem(at: out)
        let tmp = out.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try encode([master] + stems.map(\.url), tags: tags, to: tmp)
        var data = try Data(contentsOf: tmp)
        let frames = Int((try AVAudioFile(forReading: master)).length)
        try finish(&data, json: metadata(stems), frames: frames)
        try data.write(to: out, options: .atomic)
    }

    /// The JSON Stems players read: the stems' names and colours, the mastering DSP off.
    static func metadata(_ stems: [Stem]) -> Data {
        let json: [String: Any] = [
            "version": 1,
            "mastering_dsp": [
                "compressor": ["enabled": false, "ratio": 3, "output_gain": 0.5, "release": 0.3, "attack": 0.003,
                               "input_gain": 0.5, "threshold": 0, "hp_cutoff": 300, "dry_wet": 50],
                "limiter": ["enabled": false, "release": 0.05, "threshold": 0, "ceiling": -0.35],
            ],
            "stems": stems.map { ["name": $0.name, "color": $0.color] },
        ]
        return (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
    }

    // MARK: Encoding (five AAC tracks)

    private static func encode(_ files: [URL], tags: Tags, to url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        writer.shouldOptimizeForNetworkUse = false
        writer.metadata = metadataItems(tags)
        let pcm: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                                  AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
                                  AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2]
        let aac: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
                                  AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000]
        var pairs: [(AVAssetReader, AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for (i, f) in files.enumerated() {
            let asset = AVURLAsset(url: f)
            guard let track = asset.tracks(withMediaType: .audio).first else { throw ExportError.read }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcm)
            reader.add(output)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
            input.expectsMediaDataInRealTime = false
            // Only the mix plays in ordinary players; the stems are there for the DJ software.
            input.marksOutputTrackAsEnabled = i == 0
            guard writer.canAdd(input) else { throw ExportError.write("Could not add track \(i + 1)") }
            writer.add(input)
            pairs.append((reader, output, input))
        }
        guard writer.startWriting() else { throw ExportError.write(writer.error?.localizedDescription ?? "Could not start writing") }
        writer.startSession(atSourceTime: .zero)
        let group = DispatchGroup()
        for (n, (reader, output, input)) in pairs.enumerated() {
            guard reader.startReading() else { throw ExportError.read }
            group.enter()
            let queue = DispatchQueue(label: "stemfile.\(n)")
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if let sb = output.copyNextSampleBuffer() {
                        if !input.append(sb) { reader.cancelReading(); input.markAsFinished(); group.leave(); return }
                    } else {
                        input.markAsFinished(); group.leave(); return
                    }
                }
            }
        }
        group.wait()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw ExportError.write(writer.error?.localizedDescription ?? "Writing failed") }
    }

    private static func metadataItems(_ t: Tags) -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ v: NSCopying & NSObjectProtocol, type: String? = nil) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = v
            if let type { m.dataType = type }
            return m
        }
        var items = [item(.iTunesMetadataSongName, t.title as NSString),
                     item(.iTunesMetadataEncodingTool, "STEMEKI" as NSString)]
        if let a = t.artist { items.append(item(.iTunesMetadataArtist, a as NSString)) }
        if let b = t.bpm { items.append(item(.iTunesMetadataBeatsPerMin, NSNumber(value: b))) }
        if let art = t.artwork {
            let png = art.starts(with: [0x89, 0x50, 0x4E, 0x47])
            items.append(item(.iTunesMetadataCoverArt, art as NSData,
                              type: (png ? kCMMetadataBaseDataType_PNG : kCMMetadataBaseDataType_JPEG) as String))
        }
        return items
    }

    // MARK: The stem box

    /// AAC starts with 2112 samples of encoder delay (Apple's encoder, always).
    static let priming = 2112

    /// Puts moov/udta/stem (the JSON) into the file and an edit list on every track (the encoder delay cut off,
    /// exactly `frames` long, so every player starts on the first sample), fixing the sizes and, if the movie
    /// box comes before the audio, the chunk offsets.
    static func finish(_ d: inout Data, json: Data, frames: Int) throws {
        func u32(_ o: Int) -> Int { Int(d[o]) << 24 | Int(d[o + 1]) << 16 | Int(d[o + 2]) << 8 | Int(d[o + 3]) }
        func put32(_ o: Int, _ v: Int) { for k in 0..<4 { d[o + k] = UInt8((v >> (24 - 8 * k)) & 0xFF) } }
        func be32(_ v: Int) -> Data { Data([UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
        func type(_ o: Int) -> String { String(decoding: d[(o + 4)..<(o + 8)], as: UTF8.self) }
        /// Child boxes of the box at `o` (offset, size, type), its header being `header` bytes.
        func children(_ o: Int, _ size: Int, header: Int = 8) -> [(Int, Int, String)] {
            var r: [(Int, Int, String)] = [], p = o + header
            while p + 8 <= o + size {
                var s = u32(p)
                if s == 1, p + 16 <= o + size {      // 64-bit size (a large mdat)
                    s = 0; for k in 8..<16 { s = s << 8 | Int(d[p + k]) }
                } else if s == 0 { s = o + size - p }  // to the end
                guard s >= 8, p + s <= o + size else { break }
                r.append((p, s, type(p))); p += s
            }
            return r
        }
        func moovBox() throws -> (Int, Int, String) {
            guard let m = children(0, d.count, header: 0).first(where: { $0.2 == "moov" }) else { throw ExportError.write("No movie box") }
            return m
        }
        var moov = try moovBox()
        let mdatAfter = children(0, d.count, header: 0).contains { $0.2 == "mdat" && $0.0 > moov.0 }
        var grow = 0

        // Movie timescale, for the edit lists' durations.
        guard let mvhd = children(moov.0, moov.1).first(where: { $0.2 == "mvhd" }), d[mvhd.0 + 8] == 0 else {
            throw ExportError.write("Unexpected movie header")
        }
        let movieScale = u32(mvhd.0 + 20)
        let length = Int((Double(frames) * Double(movieScale) / 44100).rounded())
        put32(mvhd.0 + 24, length)

        // Edit lists, last track first (so the offsets of the ones before stay valid).
        for trak in children(moov.0, moov.1).filter({ $0.2 == "trak" }).reversed() {
            let kids = children(trak.0, trak.1)
            guard !kids.contains(where: { $0.2 == "edts" }), let tkhd = kids.first(where: { $0.2 == "tkhd" }),
                  d[tkhd.0 + 8] == 0 else { continue }
            put32(tkhd.0 + 28, length)
            let elst = be32(28) + Data("elst".utf8) + be32(0) + be32(1) + be32(length) + be32(priming) + be32(0x0001_0000)
            let edts = be32(8 + elst.count) + Data("edts".utf8) + elst
            d.insert(contentsOf: edts, at: tkhd.0 + tkhd.1)
            put32(trak.0, trak.1 + edts.count)
            grow += edts.count
        }
        put32(moov.0, moov.1 + grow)
        moov = try moovBox()

        // The stem box, in moov/udta.
        let box = be32(8 + json.count) + Data("stem".utf8) + json
        if let udta = children(moov.0, moov.1).first(where: { $0.2 == "udta" }) {
            d.insert(contentsOf: box, at: udta.0 + udta.1)
            put32(udta.0, udta.1 + box.count)
            put32(moov.0, moov.1 + box.count)
            grow += box.count
        } else {
            let u = be32(8 + box.count) + Data("udta".utf8) + box
            d.insert(contentsOf: u, at: moov.0 + moov.1)
            put32(moov.0, moov.1 + u.count)
            grow += u.count
        }

        // The audio moved by `grow` bytes if it sits after the movie box: the chunk offsets follow it.
        if mdatAfter {
            func walk(_ b: (Int, Int, String)) {
                switch b.2 {
                case "moov", "trak", "mdia", "minf", "stbl":
                    for c in children(b.0, b.1) { walk(c) }
                case "stco":
                    for i in 0..<u32(b.0 + 12) { let o = b.0 + 16 + 4 * i; put32(o, u32(o) + grow) }
                case "co64":
                    for i in 0..<u32(b.0 + 12) {
                        let o = b.0 + 16 + 8 * i
                        var v: UInt64 = 0
                        for k in 0..<8 { v = v << 8 | UInt64(d[o + k]) }
                        v += UInt64(grow)
                        for k in 0..<8 { d[o + k] = UInt8((v >> (56 - 8 * UInt64(k))) & 0xFF) }
                    }
                default: break
                }
            }
            walk(try moovBox())
        }
    }

    // MARK: Cover

    /// The original file's cover, if it has one.
    static func artwork(of url: URL) -> Data? {
        let asset = AVURLAsset(url: url)
        for f in asset.availableMetadataFormats {
            for m in asset.metadata(forFormat: f) where m.commonKey == .commonKeyArtwork {
                if let d = m.dataValue, !d.isEmpty { return d }
            }
        }
        return nil
    }

    /// A STEMEKI cover when the song has none: the four stem colours and the title.
    static func makeCover(title: String, artist: String?) -> Data? {
        let n = 1000
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let W = CGFloat(n)
        NSColor(srgbRed: 0.043, green: 0.043, blue: 0.051, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: W, height: W).fill()
        let colors = [NSColor(srgbRed: 1, green: 0.36, blue: 0.54, alpha: 1), NSColor(srgbRed: 1, green: 0.66, blue: 0.13, alpha: 1),
                      NSColor(srgbRed: 0.24, green: 0.86, blue: 0.59, alpha: 1), NSColor(srgbRed: 0.36, green: 0.66, blue: 1, alpha: 1)]
        // Four waveform lanes.
        for (i, c) in colors.enumerated() {
            let mid = W * (0.78 - 0.13 * CGFloat(i))
            c.setFill()
            var x: CGFloat = 70, k = 0
            while x < W - 70 {
                let ph = Double(k) * 0.37 + Double(i) * 1.9
                let h = CGFloat(0.2 + 0.8 * abs(sin(ph) * cos(ph * 0.31 + Double(i)))) * 44
                NSBezierPath(roundedRect: NSRect(x: x, y: mid - h, width: 7, height: h * 2), xRadius: 3, yRadius: 3).fill()
                x += 13; k += 1
            }
        }
        func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat) {
            let p = NSMutableParagraphStyle(); p.alignment = .left; p.lineBreakMode = .byTruncatingTail
            NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                       .foregroundColor: color, .paragraphStyle: p])
                .draw(in: NSRect(x: 70, y: y, width: W - 140, height: size * 1.3))
        }
        text(title, size: 64, weight: .heavy, color: .white, y: 190)
        if let artist { text(artist, size: 40, weight: .semibold, color: NSColor(white: 0.75, alpha: 1), y: 130) }
        text("STEMS · STEMEKI", size: 26, weight: .heavy, color: colors[2], y: 70)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }
}
