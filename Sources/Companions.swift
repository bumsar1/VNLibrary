import AppKit
import SwiftUI

/// Apps that open alongside a game (an OCR popup like Meikipop, a texthooker)
/// and close again when it quits. Apps that were already running are left alone.
extension Library {
    func companions(for game: Game) -> [String] {
        var out = globalCompanions
        for c in game.companions ?? [] where !out.contains(c) { out.append(c) }
        return out.filter { FileManager.default.fileExists(atPath: $0) }
    }

    func startCompanions(_ id: UUID) {
        guard let game = games.first(where: { $0.id == id }) else { return }
        for path in companions(for: game) {
            let url = URL(fileURLWithPath: path)
            let bundleID = Bundle(url: url)?.bundleIdentifier
            if let bundleID, !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
                continue    // already open: not ours to close later
            }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, _ in
                guard let app else { return }
                Task { @MainActor in self.launchedCompanions[id, default: []].append(app) }
            }
        }
    }

    func stopCompanions(_ id: UUID) {
        for app in launchedCompanions.removeValue(forKey: id) ?? [] { app.terminate() }
    }
}

/// Picks and lists companion apps; used in Settings (all games) and Edit (one game).
struct CompanionList: View {
    @Binding var paths: [String]

    var body: some View {
        ForEach(paths, id: \.self) { p in
            HStack {
                Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable().frame(width: 18, height: 18)
                Text(FileManager.default.displayName(atPath: p))
                Spacer()
                Button { paths.removeAll { $0 == p } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
            }
        }
        Button("Add App…") {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowsMultipleSelection = true
            if panel.runModal() == .OK {
                for u in panel.urls where !paths.contains(u.path) { paths.append(u.path) }
            }
        }
    }
}
