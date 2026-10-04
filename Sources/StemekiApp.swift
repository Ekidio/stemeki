import SwiftUI
import AppKit

@main
struct StemekiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = Library.shared
    @StateObject private var session = Session(library: Library.shared)

    var body: some Scene {
        Window("STEMEKI", id: "main") {
            ContentView()
                .environmentObject(library)
                .environmentObject(session)
                .frame(minWidth: 1400, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Songs…") { library.chooseFiles() }
                    .keyboardShortcut("o")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // Enter / Return: playhead to the very start (not while typing in a text field).
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.keyCode == 36 || e.keyCode == 76,
                  e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSTextView) else { return e }
            MainActor.assumeIsolated { Session.current?.goToStart() }
            return nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Files dropped on the Dock icon or opened with "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { Library.shared.add(urls) }
    }
}
