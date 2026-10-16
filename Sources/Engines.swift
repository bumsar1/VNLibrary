import Foundation

/// Which engine a Windows VN uses, worked out from its files, and what runs
/// it natively on a Mac when something does.
enum VNEngine: String, Codable {
    case siglus, reallive, kirikiri, renpy, nscripter, tyrano, rpgmaker, unity, artemis
    case catsystem, bgi, yuris, qlie, wolf, alicesoft, unknown

    var name: String {
        switch self {
        case .siglus: return "SiglusEngine"
        case .reallive: return "RealLive / AVG32"
        case .kirikiri: return "KiriKiri"
        case .renpy: return "Ren'Py"
        case .nscripter: return "NScripter"
        case .tyrano: return "TyranoScript"
        case .rpgmaker: return "RPG Maker MV/MZ"
        case .unity: return "Unity"
        case .artemis: return "Artemis"
        case .catsystem: return "CatSystem2"
        case .bgi: return "BGI / Ethornell"
        case .yuris: return "YU-RIS"
        case .qlie: return "QLIE"
        case .wolf: return "WOLF RPG Editor"
        case .alicesoft: return "AliceSoft System 3.5–4"
        case .unknown: return "Unknown"
        }
    }

    /// How to play it on a Mac.
    var hint: String {
        switch self {
        case .siglus: return "Runs natively with siglus_engine."
        case .reallive: return "Key's older engine. siglus_rs runs it natively with game_launcher_run — choose “RealLive / AVG32” under Edit → Launch with."
        case .kirikiri: return "Runs natively with KiriKiri Player — choose “KiriKiri” under Edit → Launch with. If a game won't run in it (encrypted, E-mote, data inside the .exe), port it in the VN-Ports chat."
        case .renpy: return "Ren'Py runs natively on Mac: open the game folder with the Ren'Py launcher, or use the game's Mac build."
        case .nscripter: return "ONScripter (e.g. onscripter-en) plays NScripter games natively on Mac."
        case .tyrano: return "TyranoScript games are HTML: they run in an NW.js or browser build on Mac."
        case .rpgmaker: return "RPG Maker MV/MZ games are HTML: they run with NW.js for Mac (copy the www folder into an NW.js app)."
        case .unity: return "Unity games need the developer's Mac build, or Whisky / CrossOver."
        case .alicesoft: return "Runs natively with AliceSoft Player — choose “AliceSoft” under Edit → Launch with. If a game won't run in it, bring it to the VN-Ports chat."
        case .bgi: return "Runs natively with BGI Player — choose “BGI / Ethornell” under Edit → Launch with. If a game won't run in it, bring it to the VN-Ports chat."
        case .artemis, .catsystem, .yuris, .qlie, .wolf:
            return "No native Mac runner that I know of: try Whisky / CrossOver (right-click → Try with Whisky / CrossOver)."
        case .unknown: return "Engine not recognised."
        }
    }

    var native: Bool { [.siglus, .reallive, .kirikiri, .bgi, .alicesoft, .renpy, .nscripter, .tyrano, .rpgmaker].contains(self) }

    /// Looks at the top two levels of a game folder.
    static func detect(_ folder: String) -> VNEngine {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: folder)
        var names = Set<String>()       // lower-cased file names
        var exts = Set<String>()
        var dirs = Set<String>()
        if let e = fm.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in e {
                if e.level > 2 { e.skipDescendants(); continue }
                let n = url.lastPathComponent.lowercased()
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    dirs.insert(n)
                } else {
                    names.insert(n)
                    exts.insert(url.pathExtension.lowercased())
                }
            }
        }
        func has(_ n: String) -> Bool { names.contains(n) }
        if has("scene.pck") || has("gameexe.dat") { return .siglus }
        if has("gameexe.ini") && (has("seen.txt") || names.contains { $0.hasPrefix("seen") && $0.hasSuffix(".txt") }) { return .reallive }
        if exts.contains("xp3") || has("startup.tjs") { return .kirikiri }
        if exts.contains("ain") || exts.contains("ald") { return .alicesoft }
        if dirs.contains("renpy") || exts.contains("rpa") || exts.contains("rpyc") { return .renpy }
        if has("nscript.dat") || has("0.txt") || has("00.txt") || exts.contains("nsa") || exts.contains("sar") { return .nscripter }
        if dirs.contains("tyrano") || has("tyrano.js") { return .tyrano }
        if has("rmmz_core.js") || has("rpg_core.js") || (dirs.contains("www") && has("package.json")) { return .rpgmaker }
        if has("unityplayer.dll") || dirs.contains { $0.hasSuffix("_data") } && has("globalgamemanagers") { return .unity }
        if exts.contains("pfs") || names.contains { $0.hasPrefix("root.pfs") } { return .artemis }
        if has("cs2.exe") || exts.contains("int") && has("startup.xml") { return .catsystem }
        if has("bgi.exe") || has("sysprg.arc") || has("bgi.gdb") { return .bgi }
        if exts.contains("ypf") { return .yuris }
        if dirs.contains("gamedata") && exts.contains("pack") { return .qlie }
        if has("data.wolf") || has("game.wolf") { return .wolf }
        return .unknown
    }
}

extension Library {
    /// game_launcher_run from siglus_rs: runs RealLive, AVG32 and UK2 games.
    var launcherPath: String {
        URL(fileURLWithPath: enginePath).deletingLastPathComponent().appendingPathComponent("game_launcher_run").path
    }
    var launcherFound: Bool { FileManager.default.isExecutableFile(atPath: launcherPath) }

    /// Detects engines for folders that haven't been checked yet.
    func detectEngines() {
        for i in games.indices where games[i].engine == nil && games[i].installed && games[i].kind != .macApp {
            let path = games[i].path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            games[i].engine = VNEngine.detect(path)
        }
        save()
    }
}
