import SwiftUI

/// EXPORT…: the ways to export, side by side, each with a little picture of what goes into the file.
struct ExportSheet: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss

    private struct Option {
        let kind: Session.ExportKind
        let number: Int
        let title: String
        let text: String
        let facts: [(String, String)]
        let example: String
        let blocked: String?
    }

    var body: some View {
        let options = makeOptions()
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("EXPORT").font(.system(size: 13, weight: .heavy)).tracking(3).foregroundColor(Theme.bass)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)) }
                    .buttonStyle(.plain).foregroundColor(Theme.dim)
                    .keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(options, id: \.number) { o in card(o) }
            }
            footer
        }
        .padding(22)
        .frame(width: 1340)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }

    // MARK: Options

    private func makeOptions() -> [Option] {
        let song = library.selected
        let g = session.grid
        let title = Exporter.safeName(song?.title ?? "Song")
        let tag = session.exportLanes.first?.fileTag ?? "DRUMS"
        let bpm = formatBPM(session.outputBPM ?? g?.meanBPM ?? 120)
        let noLanes = session.exportLanes.isEmpty ? "Mark at least one lane for export (⬇ on the lane)." : nil
        let loopLabel = session.loop.map { l in l.isBars ? "\(l.startBar)–\(l.endBar - 1)" : (g?.rangeLabel(l.start, l.end) ?? "") }
        let loopName = loopLabel.map { $0.replacingOccurrences(of: "–", with: "_") } ?? "17_20"
        let regions = session.regionsToExport.count
        return [
            Option(kind: .full, number: 1, title: "FULL TRACK LENGTH",
                   text: "The whole song from its first sample to its last, every marked lane as it is.",
                   facts: [("Tempo", "original"), ("Edits", "not included"), ("Length", "the whole file")],
                   example: "\(title)_\(tag)_FULL.wav", blocked: noLanes),
            Option(kind: .cue, number: 2, title: "FROM CUE TO THE END",
                   text: "From bar 1 (the CUE) to the end of the song. Every file starts on bar 1: stack them in a DAW.",
                   facts: [("Tempo", "\(bpm) BPM"), ("Edits", "included"), ("Starts", "on bar 1")],
                   example: "\(title)_\(tag)_\(bpm)bpm_CUE.wav", blocked: noLanes),
            Option(kind: .loop, number: 3, title: "LOOP",
                   text: loopLabel.map { "The loop (bars \($0)), bar-exact, ready to repeat in any DAW." }
                       ?? "The loop range, bar-exact, ready to repeat in any DAW.",
                   facts: [("Tempo", "\(bpm) BPM"), ("Edits", "included"), ("Loop points", "written (ACID)")],
                   example: "\(title)_\(tag)_\(bpm)bpm_LOOP_\(loopName).wav",
                   blocked: noLanes ?? (session.loop == nil ? "Draw a loop in the ruler first (drag in its lower strip, or U)."
                                        : !session.loopEnabled ? "The loop is off: switch LOOP on (L) to export it." : nil)),
            Option(kind: .regions, number: 4, title: regions == 1 ? "REGION" : "REGIONS",
                   text: "Every region drawn in EXPORT mode, each in its own file: a verse of the drums, a chorus of the bass…",
                   facts: [("Tempo", "\(bpm) BPM"), ("Edits", "included"), ("Files", regions == 0 ? "one per region" : "\(regions) (one per region)")],
                   example: "\(title)_\(tag)_\(bpm)bpm_REGION_17_20.wav",
                   blocked: noLanes ?? (regions == 0 ? "Draw regions on the lanes in EXPORT mode first." : nil)),
            Option(kind: .stems, number: 5, title: "DJ STEMS",
                   text: "One file for DJ software and players that open Stems (Traktor, Mixxx…): the mix and the four stems, with the title, the tempo and a cover. Any music player plays it as a normal song.",
                   facts: [("Tempo", "original"), ("Edits", "included"), ("Tracks", "mix + 4 stems"), ("Format", "AAC 256 kbps")],
                   example: "\(title).stem.mp4", blocked: nil),
        ]
    }

    private func card(_ o: Option) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ExportPicture(kind: o.kind)
                .frame(height: 96)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 6) {
                Text("\(o.number)").font(Theme.mono(11, .heavy)).foregroundColor(.black)
                    .frame(width: 18, height: 18).background(Circle().fill(Theme.bass))
                Text(o.title).font(.system(size: 12.5, weight: .heavy)).tracking(0.8)
            }
            Text(o.text).font(.system(size: 11.5)).foregroundColor(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(o.facts, id: \.0) { k, v in
                    HStack(spacing: 6) {
                        Text(k.uppercased()).font(.system(size: 8.5, weight: .heavy)).foregroundColor(Theme.dim).frame(width: 70, alignment: .leading)
                        Text(v).font(Theme.mono(10.5, .semibold)).foregroundColor(Theme.text)
                    }
                }
            }
            Text(o.example).font(Theme.mono(9)).foregroundColor(Theme.dim).lineLimit(2).truncationMode(.middle)
            Spacer(minLength: 0)
            if let why = o.blocked {
                Text(why).font(.system(size: 10.5)).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Button {
                dismiss()
                // The folder picker comes up once this sheet is gone.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { session.export(o.kind) }
            } label: {
                HStack(spacing: 6) { Image(systemName: "square.and.arrow.down.fill"); Text("EXPORT") }
                    .font(.system(size: 12, weight: .heavy)).tracking(1)
                    .frame(maxWidth: .infinity).frame(height: 32)
                    .foregroundColor(.black)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bass))
            }
            .buttonStyle(.plain)
            .disabled(o.blocked != nil || !session.canExport(o.kind))
            .opacity(o.blocked != nil || !session.canExport(o.kind) ? 0.35 : 1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 360, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
    }

    private var footer: some View {
        let song = library.selected
        let lanes = session.exportLanes.map(\.fileTag).joined(separator: ", ")
        let ext = song.map { Exporter.outputExt(forSource: $0.srcExt).uppercased() } ?? "WAV"
        let bits = song.map { $0.srcFloat ? "\($0.srcBits)-bit float" : "\($0.srcBits)-bit" } ?? ""
        let rate = song.map { String(format: "%g kHz", $0.srcSampleRate / 1000) } ?? ""
        return HStack(spacing: 18) {
            fact("LANES", lanes.isEmpty ? "none marked" : lanes + "  (one file each)")
            fact("FORMAT", "\(ext) \(bits) \(rate), like the original")
            fact("FADE", session.fadeOn ? "\(Int(session.fadeMs)) ms at both ends" : "off")
            Spacer()
        }
    }

    private func fact(_ k: String, _ v: String) -> some View {
        HStack(spacing: 6) {
            Text(k).font(.system(size: 9, weight: .heavy)).foregroundColor(Theme.dim)
            Text(v).font(Theme.mono(10.5, .semibold)).foregroundColor(Theme.text)
        }
    }
}

/// A small drawing of what an export takes from the song: four stem lanes, the part that goes into the
/// file bright, the rest dimmed.
struct ExportPicture: View {
    let kind: Session.ExportKind

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let colors = [Theme.vocals, Theme.drums, Theme.bass, Theme.other]
            let top: CGFloat = 22, laneH = (h - top - 8) / 4
            // Which part of the song (0…1) goes into the file, per lane.
            let cue: CGFloat = 0.18
            func span(_ lane: Int) -> [(CGFloat, CGFloat)] {
                switch kind {
                case .full: return [(0, 1)]
                case .cue: return [(cue, 1)]
                case .loop: return [(0.46, 0.7)]
                case .regions: return [[(0.22, 0.4)], [(0.55, 0.72), (0.8, 0.93)], [(0.3, 0.5)], []][lane]
                case .stems: return [(0, 1)]
                }
            }
            // Ruler with bar ticks.
            var ticks = Path()
            for i in 0...12 {
                let x = 8 + (w - 16) * CGFloat(i) / 12
                ticks.move(to: CGPoint(x: x, y: 12)); ticks.addLine(to: CGPoint(x: x, y: 17))
            }
            ctx.stroke(ticks, with: .color(.white.opacity(0.25)), lineWidth: 1)
            // Lanes: a waveform-like row of bars, bright where it is exported.
            for (i, c) in colors.enumerated() {
                let y0 = top + CGFloat(i) * laneH, mid = y0 + laneH / 2
                let parts = span(i)
                var k = 0
                var x: CGFloat = 8
                while x < w - 8 {
                    let u = (x - 8) / (w - 16)
                    let on = parts.contains { u >= $0.0 && u <= $0.1 }
                    let amp = (0.25 + 0.75 * abs(sin(Double(k) * 0.9 + Double(i) * 1.7) * cos(Double(k) * 0.23))) * Double(laneH) * 0.38
                    ctx.fill(Path(CGRect(x: x, y: mid - CGFloat(amp), width: 2, height: CGFloat(amp) * 2)),
                             with: .color(c.opacity(on ? 0.95 : 0.16)))
                    x += 4; k += 1
                }
                if kind == .regions {
                    for p in parts {
                        let r = CGRect(x: 8 + (w - 16) * p.0, y: y0 + 1.5, width: (w - 16) * (p.1 - p.0), height: laneH - 3)
                        ctx.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(.white), lineWidth: 1.5)
                    }
                }
            }
            switch kind {
            case .full:
                drawBracket(ctx, from: 8, to: w - 8, y: 6, label: "START → END")
            case .cue:
                let x = 8 + (w - 16) * cue
                ctx.fill(Path(CGRect(x: x - 0.75, y: top - 4, width: 1.5, height: h - top)), with: .color(Theme.accent))
                let flag = CGRect(x: x - 25, y: 2, width: 24, height: 11)
                ctx.fill(Path(roundedRect: flag, cornerRadius: 2), with: .color(Theme.accent))
                ctx.draw(Text("CUE").font(Theme.mono(7.5, .heavy)).foregroundColor(.black), at: CGPoint(x: flag.midX, y: flag.midY))
                drawBracket(ctx, from: x, to: w - 8, y: 6, label: "BAR 1 → END")
            case .loop:
                let a = 8 + (w - 16) * 0.46, b = 8 + (w - 16) * 0.7
                ctx.fill(Path(roundedRect: CGRect(x: a, y: 3, width: b - a, height: 12), cornerRadius: 3), with: .color(Theme.loop))
                ctx.draw(Text("↻ LOOP").font(Theme.mono(7.5, .heavy)).foregroundColor(.black), at: CGPoint(x: (a + b) / 2, y: 9))
            case .regions:
                ctx.draw(Text("ONE FILE PER REGION").font(Theme.mono(7.5, .heavy)).foregroundColor(.white.opacity(0.8)),
                         at: CGPoint(x: w / 2, y: 8))
            case .stems:
                drawBracket(ctx, from: 8, to: w - 8, y: 6, label: "MIX + 4 STEMS")
            }
        }
    }

    private func drawBracket(_ ctx: GraphicsContext, from a: CGFloat, to b: CGFloat, y: CGFloat, label: String) {
        var p = Path()
        p.move(to: CGPoint(x: a, y: y + 6)); p.addLine(to: CGPoint(x: a, y: y)); p.addLine(to: CGPoint(x: b, y: y)); p.addLine(to: CGPoint(x: b, y: y + 6))
        ctx.stroke(p, with: .color(Theme.bass), lineWidth: 1.5)
        let mid = (a + b) / 2
        ctx.fill(Path(roundedRect: CGRect(x: mid - 38, y: y - 6, width: 76, height: 12), cornerRadius: 3), with: .color(Theme.bg))
        ctx.draw(Text(label).font(Theme.mono(7.5, .heavy)).foregroundColor(Theme.bass), at: CGPoint(x: mid, y: y))
    }
}
