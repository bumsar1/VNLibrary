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
        // Keyed by the player's Start script and its date too, so a new player
        // version (which may resolve folders differently) asks again.
        let stamp = (try? FileManager.default.attributesOfItem(atPath: kirikiriStart)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let cacheKey = "\(kirikiriStart)|\(stamp)|\(game.path)"
        if let cached = Self.kirikiriPathCache[cacheKey] { return cached }
        let paths = Self.runQuick(kirikiriStart, ["--print-paths", game.path])
            .flatMap { $0.split(separator: "\n").last(where: { $0.hasPrefix("{") }) }
            .flatMap { try? JSONDecoder().decode(KiriKiriPaths.self, from: Data($0.utf8)) }
        Self.kirikiriPathCache[cacheKey] = .some(paths)   // remember failures too
        return paths
    }

    /// A folder KiriKiri Player can run although detection didn't spot it:
    /// older games keep all their data inside the .exe, and a download often
    /// unpacks to a folder whose one subfolder is the game (the player uses
    /// that subfolder). `Start --check` is quick, starts no engine and exits 0
    /// when it can. Only asked for folders with an .exe at the top or one level down.
    func kirikiriCanRun(_ folder: String) -> Bool {
        guard kirikiriFound else { return false }
        let fm = FileManager.default
        func hasExe(_ dir: String) -> Bool {
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).contains { $0.lowercased().hasSuffix(".exe") }
        }
        let subdirs = ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).map { (folder as NSString).appendingPathComponent($0) }
            .filter { var d: ObjCBool = false; return fm.fileExists(atPath: $0, isDirectory: &d) && d.boolValue }
        guard hasExe(folder) || subdirs.contains(where: hasExe) else { return false }
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
            Text("Runs KiriKiri games natively: folders with data.xp3 or startup.tjs, older games with everything inside the .exe, and folders whose one subfolder is the game. Built in the VN-Ports project; games it can't run get a full port there.")
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
