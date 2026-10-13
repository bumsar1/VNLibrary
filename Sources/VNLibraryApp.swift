import AppKit
import SwiftUI

@main
struct VNLibraryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var lib = Library.shared

    var body: some Scene {
        WindowGroup("VN Library") {
            ContentView()
                .environmentObject(lib)
                .frame(minWidth: 720, minHeight: 520)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Games…") {
                    NotificationCenter.default.post(name: .addGames, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
                Button("Fetch Missing from VNDB") { Library.shared.fetchMissingVNDB() }
                Button("Update VNDB Data (Tags etc.)") { Library.shared.refreshVNDB() }
            }
            CommandGroup(after: .sidebar) {
                Button("Discreet Mode") { Library.shared.discreet.toggle() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Couch Mode") { NotificationCenter.default.post(name: .toggleCouch, object: nil) }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Pick a Random Game") { NotificationCenter.default.post(name: .randomGame, object: nil) }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        // Test hooks (environment, not argv; see the Keiko notes).
        if let add = env["VNLIB_ADD"] {
            let urls = add.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
            MainActor.assumeIsolated { _ = Library.shared.add(urls: urls) }
        }
        if let vid = env["VNLIB_DISCOVER_ADD"] {
            Task { @MainActor in
                if let r = try? await VNDB.fetch(id: vid) { await Library.shared.addFromVNDB(r) }
            }
        }
        if env["VNLIB_LAUNCH_FIRST"] != nil {
            MainActor.assumeIsolated {
                if let first = Library.shared.games.first { Library.shared.launch(first) }
            }
        }
        if let out = env["VNLIB_SNAPSHOT"] {
            let delay = Double(env["VNLIB_SNAPSHOT_DELAY"] ?? "") ?? 2.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                // One PNG per visible window, so sheets are captured too.
                for (n, window) in NSApp.windows.filter(\.isVisible).enumerated() {
                    guard let view = window.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let path = n == 0 ? out : out.replacingOccurrences(of: ".png", with: "-\(n).png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                exit(0)    // terminate(nil) waits on an open sheet
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Folders or apps dropped on the Dock icon are added to the library.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { _ = Library.shared.add(urls: urls) }
    }
}
