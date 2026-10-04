import Sparkle
import SwiftUI

/// Self-updates via Sparkle: checks the appcast on GitHub daily and offers new versions.
/// Updates are verified with the EdDSA key in SUPublicEDKey, so no Apple Developer ID is needed.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    @Published private(set) var canCheckForUpdates = false
    private let delegate = UpdaterDelegate()
    private let controller: SPUStandardUpdaterController

    /// Without a feed (GITHUB_REPO empty in release.conf) Sparkle would show a startup error, so stay off.
    static var isConfigured: Bool {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        return !(feed ?? "").isEmpty || UserDefaults.standard.string(forKey: "UpdateFeedURL") != nil
    }

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: Self.isConfigured,
                                                  updaterDelegate: delegate, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    /// Test against a local appcast:
    /// `defaults write hu.ekidio.STEMEKI UpdateFeedURL http://localhost:8765/appcast.xml`
    func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "UpdateFeedURL")
    }
}
