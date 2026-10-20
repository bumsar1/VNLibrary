import AppKit
import SwiftUI

/// Engine players built in the VN-Ports project and bundled with VN Library:
/// each is an .app whose Start script runs a raw Windows game folder natively.
/// They share one contract:
/// - `Start "<folder>"` execs the engine, so the process VN Library starts is the game;
///   couch launches pass VNLIB_FULLSCREEN=1 and the player goes full screen itself.
/// - `Start --check "<folder>"` exits 0 when it can run the folder.
/// - `Start --print-paths "<folder>"` prints {"id", "saves", "log", "engineLog"?}.
/// - `Start --version` prints one line.
/// - A failed start ends with one "<PREFIX>: <reason>" line on stderr.
enum BundledPlayer: String, CaseIterable, Identifiable {
    case kirikiri, bgi, alicesoft
    var id: String { rawValue }

    var title: String {
        switch self {
        case .kirikiri: return "KiriKiri Player"
        case .bgi: return "BGI Player"
        case .alicesoft: return "AliceSoft Player"
        }
    }
    var appName: String { title + ".app" }
    var reasonPrefix: String {
        switch self {
        case .kirikiri: return "KIRIKIRI_PLAYER:"
        case .bgi: return "BGI_PLAYER:"
        case .alicesoft: return "ALICESOFT_PLAYER:"
        }
    }
    var kind: LaunchKind {
        switch self {
        case .kirikiri: return .kirikiri
        case .bgi: return .bgi
        case .alicesoft: return .alicesoft
        }
    }
    var engine: VNEngine {
        switch self {
        case .kirikiri: return .kirikiri
        case .bgi: return .bgi
        case .alicesoft: return .alicesoft
        }
    }
    /// What the player accepts, for Settings and Edit.
    var accepts: String {
        switch self {
        case .kirikiri:
            return "KiriKiri games: folders with data.xp3 or startup.tjs, older games with everything inside the .exe, and folders whose one subfolder is the game."
        case .bgi:
            return "BGI / Ethornell games (sysprg.arc and system.arc, e.g. Lump of Sugar, August), also when the game is one subfolder down. Unpacked trial versions work as they are."
        case .alicesoft:
            return "AliceSoft games on System 3.5–3.9 (.ALD archives, e.g. Rance 4.1) and System 4 (.ain, e.g. Rance 02), also when the game is one subfolder down."
        }
    }
    /// Something the player can't do yet, shown wherever its games appear.
    var knownLimit: String? {
        nil  // none right now (BGI Player 0.1.4 fixed save loading)
    }

    var cantRunHint: String {
        switch self {
        case .kirikiri: return "If it's a KiriKiri game the player can't run (encrypted, or with unusual plugins), bring it to the VN-Ports chat for a full port."
        case .bgi: return "If it's a BGI game the player can't run, bring it to the VN-Ports chat."
        case .alicesoft: return "If it's an AliceSoft game the player can't run, bring it to the VN-Ports chat."
        }
    }
    /// A cheap look before asking `Start --check`: files the engine needs,
    /// at the top of the folder or one level down.
    fileprivate func mightRun(_ names: Set<String>) -> Bool {
        switch self {
        case .kirikiri: return names.contains { $0.hasSuffix(".exe") || $0.hasSuffix(".xp3") }
        case .bgi: return names.contains("sysprg.arc")
        case .alicesoft: return names.contains { $0.hasSuffix(".ald") || $0.hasSuffix(".ain") }
        }
    }

    static func of(_ kind: LaunchKind) -> BundledPlayer? { allCases.first { $0.kind == kind } }
    static func of(_ engine: VNEngine) -> BundledPlayer? { allCases.first { $0.engine == engine } }
}

extension Library {
    static let installedPlayersDir = "~/Applications"
    static func bundledPlayer(_ p: BundledPlayer) -> String? {
        Bundle.main.resourceURL.map { $0.appendingPathComponent(p.appName).path }
    }

    private static func startScript(_ path: String) -> String {
        let p = (path as NSString).expandingTildeInPath
        return p.hasSuffix(".app") ? p + "/Contents/MacOS/Start" : p
    }

    enum PlayerSource { case override, bundled, installed }

    func playerOverride(_ p: BundledPlayer) -> String { playerOverrides[p.rawValue] ?? "" }

    /// Which copy is used: the Settings override when it exists, then the copy
    /// inside VN Library, then ~/Applications. Saves don't depend on it.
    func playerResolved(_ p: BundledPlayer) -> (start: String, source: PlayerSource) {
        let fm = FileManager.default
        let custom = playerOverride(p)
        if !custom.isEmpty, fm.isExecutableFile(atPath: Self.startScript(custom)) { return (Self.startScript(custom), .override) }
        if let b = Self.bundledPlayer(p), fm.isExecutableFile(atPath: Self.startScript(b)) { return (Self.startScript(b), .bundled) }
        return (Self.startScript(Self.installedPlayersDir + "/" + p.appName), .installed)
    }
    func playerStart(_ p: BundledPlayer) -> String { playerResolved(p).start }
    func playerFound(_ p: BundledPlayer) -> Bool { FileManager.default.isExecutableFile(atPath: playerStart(p)) }

    struct PlayerPaths: Decodable { let id: String; let saves: String; let log: String; let engineLog: String? }

    /// `Start --print-paths`: where the player keeps a game's saves and logs.
    func playerPaths(for game: Game) -> PlayerPaths? {
        guard let p = BundledPlayer.of(game.kind), playerFound(p), game.installed else { return nil }
        let start = playerStart(p)
        // Keyed by the Start script and its date too, so a new player version
        // (which may resolve folders differently) is asked again.
        let stamp = (try? FileManager.default.attributesOfItem(atPath: start)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let key = "\(start)|\(stamp)|\(game.path)"
        if let cached = Self.playerPathCache[key] { return cached }
        let paths = Self.runQuick(start, ["--print-paths", game.path])
            .flatMap { $0.split(separator: "\n").last(where: { $0.hasPrefix("{") }) }
            .flatMap { try? JSONDecoder().decode(PlayerPaths.self, from: Data($0.utf8)) }
        Self.playerPathCache[key] = .some(paths)   // remember failures too
        return paths
    }

    /// The player that can run a folder detection didn't settle, by asking
    /// `Start --check` (quick, starts no engine). Only players whose files are
    /// in the folder or up to three folders below are asked.
    func playerThatCanRun(_ folder: String) -> BundledPlayer? {
        // File names down to three folders below (the players find a single game
        // that deep, e.g. trial/190412_trial/game/), capped so a huge folder stays quick.
        let fm = FileManager.default
        var all = Set<String>()
        var level = [folder]
        var visited = 0
        for _ in 0...3 {
            var next: [String] = []
            for dir in level where visited < 300 {
                visited += 1
                for item in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where !item.hasPrefix(".") {
                    all.insert(item.lowercased())
                    let sub = (dir as NSString).appendingPathComponent(item)
                    var d: ObjCBool = false
                    if fm.fileExists(atPath: sub, isDirectory: &d), d.boolValue, !item.hasSuffix(".app") { next.append(sub) }
                }
            }
            level = next
        }
        return BundledPlayer.allCases.first { p in
            p.mightRun(all) && playerFound(p) && Self.runQuick(playerStart(p), ["--check", folder]) != nil
        }
    }

    /// The launch kind for a folder: a bundled player when one recognises it.
    func playerKind(for folder: String, engine: VNEngine?) -> LaunchKind? {
        // The player has the last word: e.g. KiriKiri Player turns down data.xp3
        // archives encrypted with a key inside the Windows exe.
        if let e = engine, let p = BundledPlayer.of(e), playerFound(p),
           Self.runQuick(playerStart(p), ["--check", folder]) != nil {
            return p.kind
        }
        return playerThatCanRun(folder)?.kind
    }

    nonisolated static func playerVersion(_ start: String) -> String? {
        runQuick(start, ["--version"])?.split(separator: "\n").first.map(String.init)
    }

    nonisolated(unsafe) private static var playerPathCache: [String: PlayerPaths?] = [:]

    /// Runs a short command and returns its stdout (nil on failure).
    nonisolated static func runQuick(_ executable: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        // Read to EOF first (the player prints a line and exits), then reap it.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Settings: where a player is, and which version.
struct PlayerSection: View {
    @EnvironmentObject var lib: Library
    let player: BundledPlayer
    @State private var version: String?

    private var override: Binding<String> {
        Binding(get: { lib.playerOverride(player) }, set: { lib.playerOverrides[player.rawValue] = $0.isEmpty ? nil : $0 })
    }

    var body: some View {
        let resolved = lib.playerResolved(player)
        Section {
            HStack {
                TextField("Automatic (the copy inside VN Library)", text: override)
                    .font(.system(size: 12, design: .monospaced))
                Button("Choose…") { choose() }
                if !lib.playerOverride(player).isEmpty { Button("Automatic") { override.wrappedValue = "" } }
            }
            Label(statusText(resolved.source), systemImage: lib.playerFound(player) ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(lib.playerFound(player) ? Color.kDone : Color.kHinomaru)
            if !lib.playerOverride(player).isEmpty && resolved.source != .override {
                Text("The chosen player wasn't found, so the automatic one is used.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } header: {
            Text(player.title)
        } footer: {
            Text("Runs \(player.accepts) Built in the VN-Ports project." + (player.knownLimit.map { "\n\nKnown limit: " + $0 } ?? ""))
        }
        .task(id: resolved.start) {
            let start = resolved.start
            version = lib.playerFound(player) ? await Task.detached { Library.playerVersion(start) }.value : nil
        }
    }

    private func statusText(_ source: Library.PlayerSource) -> String {
        guard lib.playerFound(player) else { return "\(player.title) not found" }
        let v = version ?? player.title
        switch source {
        case .bundled: return "\(v) · bundled with VN Library"
        case .override: return "\(v) · \(lib.playerOverride(player))"
        case .installed: return "\(v) · ~/Applications"
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: ("~/Applications" as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url { override.wrappedValue = url.path }
    }
}
