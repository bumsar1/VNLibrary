import SwiftUI

/// Trying a Windows game through Whisky or CrossOver, to see whether it runs
/// well enough before settling on it (some games are better ported natively).
enum WineRunner: Hashable, Identifiable {
    case whisky(name: String, prefix: String)
    case crossover(name: String)

    var id: String { label }
    var label: String {
        switch self {
        case .whisky(let n, _): return "Whisky · \(n)"
        case .crossover(let n): return "CrossOver · \(n)"
        }
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    private static let whiskyWine = home + "/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin/wine64"
    private static let crossoverWine = "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine"

    /// Every Whisky and CrossOver bottle on this Mac.
    static func available() -> [WineRunner] {
        let fm = FileManager.default
        var out: [WineRunner] = []
        if fm.isExecutableFile(atPath: whiskyWine) {
            let dir = home + "/Library/Containers/com.isaacmarovitz.Whisky/Bottles"
            for b in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                let path = dir + "/" + b
                let meta = NSDictionary(contentsOfFile: path + "/Metadata.plist")
                let name = (meta?["info"] as? [String: Any])?["name"] as? String ?? b
                out.append(.whisky(name: name, prefix: path))
            }
        }
        if fm.isExecutableFile(atPath: crossoverWine) {
            let dir = home + "/Library/Application Support/CrossOver/Bottles"
            for b in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() where !b.hasPrefix(".") {
                out.append(.crossover(name: b))
            }
        }
        return out
    }

    /// The shell command that runs `exe`. A Japanese locale matters for most
    /// VNs: without it Shift-JIS text and file names come out garbled.
    func command(exe: String, japanese: Bool) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let dir = (exe as NSString).deletingLastPathComponent
        let locale = japanese ? "LANG=ja_JP.UTF-8 LC_ALL=ja_JP.UTF-8 " : ""
        switch self {
        case .whisky(_, let prefix):
            return "cd \(q(dir)) && \(locale)WINEPREFIX=\(q(prefix)) WINEMSYNC=1 \(q(Self.whiskyWine)) \(q(exe))"
        case .crossover(let name):
            return "cd \(q(dir)) && \(locale)\(q(Self.crossoverWine)) --bottle \(q(name)) \(q(exe))"
        }
    }
}

extension Library {
    /// Likely game executables in a folder, biggest first, without
    /// installers, uninstallers and config tools.
    func executables(in folder: String) -> [String] {
        let skip = ["unins", "setup", "install", "config", "crash", "vcredist", "dxsetup", "directx", "update", "launcher_setup", "dotnet"]
        let base = URL(fileURLWithPath: folder)
        guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.fileSizeKey],
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [(String, Int)] = []
        for case let url as URL in e {
            if e.level > 2 { e.skipDescendants(); continue }
            guard url.pathExtension.lowercased() == "exe" else { continue }
            let n = url.lastPathComponent.lowercased()
            if skip.contains(where: { n.contains($0) }) { continue }
            found.append((url.path, (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Runs a game with a one-off command, tracked like a normal launch.
    func launch(_ game: Game, command: String) {
        guard running[game.id] == nil else { return }
        var g = game
        g.kind = .command
        g.command = command
        launch(g)
    }
}

struct WineTrySheet: View {
    @EnvironmentObject var lib: Library
    @Environment(\.dismiss) private var dismiss
    let game: Game

    @State private var exes: [String] = []
    @State private var runners: [WineRunner] = WineRunner.available()
    @State private var exe = ""
    @State private var runner: WineRunner?
    @State private var japanese = true
    @State private var tried = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Try with Whisky or CrossOver").font(.system(size: 18, weight: .bold))
            Text("Runs the Windows version of \(lib.displayName(game)) through Wine so you can see how well it works. Nothing changes until you choose Keep.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if runners.isEmpty {
                Text("Neither Whisky nor CrossOver (with a bottle) was found on this Mac.")
                    .foregroundStyle(Color.kHinomaru).font(.system(size: 12))
            }
            if exes.isEmpty {
                Text("No .exe found in the game folder.").foregroundStyle(Color.kHinomaru).font(.system(size: 12))
            }
            Form {
                Picker("Program", selection: $exe) {
                    ForEach(exes, id: \.self) { p in
                        Text(p.replacingOccurrences(of: game.path + "/", with: "")).tag(p)
                    }
                }
                Picker("Run with", selection: $runner) {
                    ForEach(runners) { r in Text(r.label).tag(Optional(r)) }
                }
                Toggle("Japanese locale (fixes garbled text in most VNs)", isOn: $japanese)
            }
            .formStyle(.grouped)
            if tried {
                Text("Started. If it runs well, choose Keep to always launch it this way. You can switch back under Edit → Launch with.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Try It") {
                    guard let cmd else { return }
                    lib.launch(game, command: cmd)
                    tried = true
                }
                .disabled(cmd == nil || lib.running[game.id] != nil)
                Button("Keep This Setup") {
                    guard let cmd, let i = lib.games.firstIndex(where: { $0.id == game.id }) else { return }
                    lib.games[i].kind = .command
                    lib.games[i].command = cmd
                    lib.save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(cmd == nil)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear {
            exes = lib.executables(in: game.path)
            exe = exes.first ?? ""
            runner = runners.first
        }
    }

    private var cmd: String? {
        guard let runner, !exe.isEmpty else { return nil }
        return runner.command(exe: exe, japanese: japanese)
    }
}
