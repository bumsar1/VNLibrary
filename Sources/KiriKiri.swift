import AppKit
import SwiftUI

/// KiriKiri Player: a generic krkrsdl2 build from the VN-Ports project that
/// runs raw KiriKiri game folders. VN Library runs `Start "<folder>"`; the
/// script execs the engine, so the process VN Library starts is the game.
extension Library {
    static let installedKirikiriPlayer = "~/Applications/KiriKiri Player.app"
    static var bundledKirikiriPlayer: String? {
        Bundle.main.resourceURL.map { $0.appendingPathComponent("KiriKiri Player.app").path }
    }

    private static func startScript(_ path: String) -> String {
        let p = (path as NSString).expandingTildeInPath
        return p.hasSuffix(".app") ? p + "/Contents/MacOS/Start" : p
    }

    enum KiriKiriSource { case override, bundled, installed }

    /// Which player is used: the Settings override when it exists, then the
    /// copy inside VN Library, then ~/Applications. Saves don't depend on it.
    var kirikiriResolved: (start: String, source: KiriKiriSource) {
        let fm = FileManager.default
        if !kirikiriPlayer.isEmpty, fm.isExecutableFile(atPath: Self.startScript(kirikiriPlayer)) {
            return (Self.startScript(kirikiriPlayer), .override)
        }
        if let b = Self.bundledKirikiriPlayer, fm.isExecutableFile(atPath: Self.startScript(b)) {
            return (Self.startScript(b), .bundled)
        }
        return (Self.startScript(Self.installedKirikiriPlayer), .installed)
    }
    var kirikiriStart: String { kirikiriResolved.start }
    var kirikiriFound: Bool { FileManager.default.isExecutableFile(atPath: kirikiriStart) }

    /// `Start --print-paths`: where the player keeps a game's saves and logs.
    struct KiriKiriPaths: Decodable { let id: String; let saves: String; let log: String; let engineLog: String? }

    func kirikiriPaths(for game: Game) -> KiriKiriPaths? {
        guard game.kind == .kirikiri, kirikiriFound, game.installed else { return nil }
        if let cached = Self.kirikiriPathCache[game.path] { return cached }
        let paths = Self.runQuick(kirikiriStart, ["--print-paths", game.path])
            .flatMap { $0.split(separator: "\n").last(where: { $0.hasPrefix("{") }) }
            .flatMap { try? JSONDecoder().decode(KiriKiriPaths.self, from: Data($0.utf8)) }
        Self.kirikiriPathCache[game.path] = .some(paths)   // remember failures too
        return paths
    }

    /// A folder KiriKiri Player can run although it has no .xp3 or
    /// startup.tjs: older games keep all their data inside the .exe.
    /// `Start --check` is quick, starts no engine and exits 0 when it can.
    func kirikiriCanRun(_ folder: String) -> Bool {
        guard kirikiriFound,
              let items = try? FileManager.default.contentsOfDirectory(atPath: folder),
              items.contains(where: { $0.lowercased().hasSuffix(".exe") }) else { return false }
        return Self.runQuick(kirikiriStart, ["--check", folder]) != nil
    }

    /// One line, e.g. "KiriKiri Player 0.1.0 (krkrsdl2 latest 2026-08-31)".
    nonisolated static func kirikiriVersion(_ start: String) -> String? {
        runQuick(start, ["--version"])?.split(separator: "\n").first.map(String.init)
    }

    nonisolated(unsafe) private static var kirikiriPathCache: [String: KiriKiriPaths?] = [:]

    /// Runs a short command and returns its stdout (nil on failure).
    nonisolated static func runQuick(_ executable: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        // Read to EOF first (the player prints one line and exits), then reap it.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Settings: where KiriKiri Player is, and which version.
struct KiriKiriPlayerSection: View {
    @EnvironmentObject var lib: Library
    @State private var version: String?

    var body: some View {
        Section {
            HStack {
                TextField("Automatic (the copy inside VN Library)", text: $lib.kirikiriPlayer)
                    .font(.system(size: 12, design: .monospaced))
                Button("Choose…") { choose() }
                if !lib.kirikiriPlayer.isEmpty { Button("Automatic") { lib.kirikiriPlayer = "" } }
            }
            Label(statusText, systemImage: lib.kirikiriFound ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(lib.kirikiriFound ? Color.kDone : Color.kHinomaru)
            if !lib.kirikiriPlayer.isEmpty && lib.kirikiriResolved.source != .override {
                Text("The chosen player wasn't found, so the automatic one is used.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } header: {
            Text("KiriKiri Player")
        } footer: {
            Text("Runs raw KiriKiri game folders (data.xp3) natively. Built in the VN-Ports project; games it can't run get a full port there.")
        }
        .task(id: lib.kirikiriStart) {
            let start = lib.kirikiriStart
            version = lib.kirikiriFound ? await Task.detached { Library.kirikiriVersion(start) }.value : nil
        }
    }

    private var statusText: String {
        guard lib.kirikiriFound else { return "KiriKiri Player not found" }
        let v = version ?? "KiriKiri Player"
        switch lib.kirikiriResolved.source {
        case .bundled: return "\(v) · bundled with VN Library"
        case .override: return "\(v) · \(lib.kirikiriPlayer)"
        case .installed: return "\(v) · ~/Applications"
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: ("~/Applications" as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url { lib.kirikiriPlayer = url.path }
    }
}
