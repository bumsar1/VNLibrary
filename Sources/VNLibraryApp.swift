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
                Button("Update jiten.moe Data") { Library.shared.refreshJitenAll() }
            }
            CommandGroup(after: .sidebar) {
                Button("Discreet Mode") { Library.shared.discreet.toggle() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Blur Shown Images Again") { Library.shared.revealed.removeAll() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
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
        // The default cache (a few MB) is far too small for cover-heavy views:
        // Discover and couch mode kept downloading the same images again.
        URLCache.shared = URLCache(memoryCapacity: 128 << 20, diskCapacity: 1 << 30)
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
        // Test hook: "delete:<text>" or "blacklist:<text>" on the first game's counted lines.
        if let action = env["VNLIB_READ_ACTION"], let colon = action.firstIndex(of: ":") {
            MainActor.assumeIsolated {
                let lib = Library.shared
                let text = String(action[action.index(after: colon)...])
                if let g = lib.games.first {
                    let ids = Set(lib.readLines(game: g.id).filter { $0.text == text }.map(\.id))
                    lib.deleteReadLines(ids, game: g.id, blacklist: action.hasPrefix("blacklist"))
                }
            }
        }
        // A JSON list of exact lines to blacklist in every game (one-off clean-ups).
        if let path = env["VNLIB_BLACKLIST_FILE"],
           let texts = try? JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: path))) {
            MainActor.assumeIsolated {
                let lib = Library.shared
                let set = Set(texts)
                for g in lib.games {
                    let ids = Set(lib.readLines(game: g.id).filter { set.contains($0.text) }.map(\.id))
                    if !ids.isEmpty { lib.deleteReadLines(ids, game: g.id, blacklist: true) }
                }
            }
        }
        if env["VNLIB_READ_TEXT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                MainActor.assumeIsolated {
                    if let s = Library.shared.sessions.last {
                        NotificationCenter.default.post(name: .openReadText, object: [s.gameID, s.id])
                    }
                }
            }
        }
        if let dev = env["VNLIB_DEVELOPER"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { Library.shared.showDeveloper(name: dev, id: nil) }
            }
        }
        if let how = env["VNLIB_LAUNCH_FIRST"] {    // "couch" launches like couch mode
            MainActor.assumeIsolated {
                if let first = Library.shared.games.first { Library.shared.launch(first, fullScreen: how == "couch") }
            }
        }
        if env["VNLIB_AX_CHECK"] != nil {
            print("AX trusted:", FullScreen.ensureAccess(prompt: false))
            exit(0)
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
