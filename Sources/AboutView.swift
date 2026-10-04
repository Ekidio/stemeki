import SwiftUI

/// About STEMEKI, in the spirit of the DAWEKI credits box.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var updater = Updater.shared
    @State private var phase = 0.0

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "v\(v)"
    }

    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.animation) { tl in
                StemekiLogo(height: 54, phase: tl.date.timeIntervalSinceReferenceDate)
            }
            .padding(.top, 30)
            Text("STEMS  ·  LOOPS  ·  REMIX")
                .font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(2)
                .foregroundColor(Theme.dim).padding(.top, 14)
            HStack(spacing: 5) {
                ForEach(StemekiLogo.bandColors.indices, id: \.self) { i in
                    Capsule().fill(StemekiLogo.bandColors[i]).frame(width: 46, height: 3)
                }
            }
            .padding(.top, 10)

            VStack(spacing: 6) {
                Text("STEMEKI • \(version)").font(Theme.mono(13, .bold)).foregroundColor(.white)
                Text("Vibe Coder: ANDRAS ECKERT").font(Theme.mono(12, .semibold)).foregroundColor(Theme.text)
                Text("eckertandris@gmail.com").font(Theme.mono(12)).foregroundColor(Theme.accent)
                    .textSelection(.enabled)
                Text("An EKIDIO SOUND app · PADEKI · DAWEKI V3").font(Theme.mono(11)).foregroundColor(Theme.dim)
                    .padding(.top, 8)
                Text("Stem separation by Demucs (MIT)").font(Theme.mono(11)).foregroundColor(Theme.dim)
                Text("All rights reserved © 2026").font(Theme.mono(11)).foregroundColor(Theme.dim)
                    .padding(.top, 8)
            }
            .multilineTextAlignment(.center)
            .padding(.top, 24)

            HStack(spacing: 8) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .buttonStyle(PillButtonStyle(small: true))
                    .disabled(!updater.canCheckForUpdates)
                Button("Website") { NSWorkspace.shared.open(URL(string: "https://ekidio.github.io/stemeki/")!) }
                    .buttonStyle(PillButtonStyle(small: true))
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(PillButtonStyle(color: Theme.accent, filled: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            .padding(.top, 14)
        }
        .frame(width: 460)
        .background(
            ZStack {
                Theme.panel
                RadialGradient(colors: [Theme.other.opacity(0.18), .clear], center: .init(x: 0.5, y: 0.15), startRadius: 0, endRadius: 280)
            }
        )
        .preferredColorScheme(.dark)
    }
}
