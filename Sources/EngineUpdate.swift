import Foundation

/// Keeps the self-built siglus_engine current: compares the local checkout
/// with GitHub and pulls + rebuilds on request.
enum EngineUpdate {
    enum Status: Equatable {
        case unknown, checking
        case upToDate(date: String)
        case available(message: String, date: String)
        case building(step: String)
        case failed(String)
        case noRepo
    }

    /// The git checkout siglus_engine was built from (the folder above `target`).
    static func repo(for enginePath: String) -> URL? {
        var url = URL(fileURLWithPath: enginePath).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url }
            url.deleteLastPathComponent()
        }
        return nil
    }

    @discardableResult
    static func run(_ exe: String, _ args: [String], in dir: URL, log: FileHandle? = nil) async -> (Int32, String) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            p.currentDirectoryURL = dir
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"] ?? "") + ":" + FileManager.default.homeDirectoryForCurrentUser.path + "/.cargo/bin:/usr/bin:/bin"
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            let collected = Collector()
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                collected.append(d)
                log?.write(d)
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                collected.append(pipe.fileHandleForReading.readDataToEndOfFile())
                cont.resume(returning: (proc.terminationStatus, collected.text))
            }
            do { try p.run() } catch { cont.resume(returning: (-1, error.localizedDescription)) }
        }
    }

    /// Output gathered from a pipe's background handler.
    private final class Collector: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(data: data, encoding: .utf8) ?? "" }
    }

    static func git(_ args: [String], in dir: URL) async -> String {
        await run("/usr/bin/git", args, in: dir).1.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Commit: Decodable {
        struct Inner: Decodable { struct Who: Decodable { let date: String }; let message: String; let committer: Who }
        let sha: String
        let commit: Inner
    }

    static func check(enginePath: String) async -> Status {
        guard let repo = repo(for: enginePath) else { return .noRepo }
        let local = await git(["rev-parse", "HEAD"], in: repo)
        let branch = await git(["rev-parse", "--abbrev-ref", "HEAD"], in: repo)
        let origin = await git(["remote", "get-url", "origin"], in: repo)
        // github.com/<owner>/<repo>(.git)
        let parts = origin.replacingOccurrences(of: ".git", with: "").split(separator: "/").suffix(2)
        guard parts.count == 2,
              let url = URL(string: "https://api.github.com/repos/\(parts.joined(separator: "/"))/commits/\(branch)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let c = try? JSONDecoder().decode(Commit.self, from: data) else {
            return .failed("Couldn't reach GitHub.")
        }
        let date = String(c.commit.committer.date.prefix(10))
        return c.sha == local ? .upToDate(date: date)
            : .available(message: String(c.commit.message.split(separator: "\n").first ?? ""), date: date)
    }
}

extension Library {
    var engineLog: URL { logsDir.appendingPathComponent("engine-build.log") }

    func checkEngine() {
        guard engineUpdate != .checking else { return }
        if case .building = engineUpdate { return }
        engineUpdate = .checking
        Task { engineUpdate = await EngineUpdate.check(enginePath: enginePath) }
    }

    /// git pull + cargo build, logged to engine-build.log. `pull: false`
    /// only builds (e.g. to add game_launcher_run to an existing checkout).
    func updateEngine(pull: Bool = true) {
        guard let repo = EngineUpdate.repo(for: enginePath) else { engineUpdate = .noRepo; return }
        FileManager.default.createFile(atPath: engineLog.path, contents: nil)
        let log = try? FileHandle(forWritingTo: engineLog)
        Task {
            if pull {
                engineUpdate = .building(step: "Downloading changes…")
                let (pullStatus, pullOut) = await EngineUpdate.run("/usr/bin/git", ["pull", "--ff-only"], in: repo, log: log)
                guard pullStatus == 0 else {
                    engineUpdate = .failed("git pull failed: " + (pullOut.split(separator: "\n").last.map(String.init) ?? ""))
                    return
                }
            }
            engineUpdate = .building(step: "Building (a few minutes)…")
            let cargo = FileManager.default.homeDirectoryForCurrentUser.path + "/.cargo/bin/cargo"
            // siglus_engine for Siglus games, game_launcher_run for RealLive / AVG32 / UK2.
            let (status, out) = await EngineUpdate.run(cargo, ["build", "--release", "-p", "siglus_scene_vm", "--bin", "siglus_engine",
                                                              "-p", "game_launcher", "--bin", "game_launcher_run"],
                                                       in: repo, log: log)
            try? log?.close()
            if status == 0 {
                engineUpdate = await EngineUpdate.check(enginePath: enginePath)
            } else {
                let err = out.split(separator: "\n").last(where: { $0.contains("error") }).map(String.init) ?? "see the build log"
                engineUpdate = .failed("Build failed: \(err)")
            }
        }
    }
}

import SwiftUI

/// Update status and button for siglus_engine, in Settings.
struct EngineUpdateRow: View {
    @EnvironmentObject var lib: Library

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Group {
                switch lib.engineUpdate {
                case .unknown: Text("Updates not checked yet").foregroundStyle(.secondary)
                case .checking: Text("Checking GitHub…").foregroundStyle(.secondary)
                case .upToDate(let d): Label("Up to date (\(d))", systemImage: "checkmark.circle").foregroundStyle(Color.kDone)
                case .available(let m, let d): Label("Update available (\(d)): \(m)", systemImage: "arrow.down.circle.fill").foregroundStyle(Color.kAccent)
                case .building(let step): HStack { ProgressView().controlSize(.small); Text(step) }
                case .failed(let e): Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(Color.kHinomaru)
                case .noRepo: Text("Not built from a git checkout, so it can't update itself.").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12))
            .lineLimit(2)
            Spacer()
            if case .available = lib.engineUpdate {
                Button("Update & Build") { lib.updateEngine() }
            } else if case .building = lib.engineUpdate {
                EmptyView()
            } else {
                Button("Check for Updates") { lib.checkEngine() }
            }
            if !lib.launcherFound, EngineUpdate.repo(for: lib.enginePath) != nil {
                if case .building = lib.engineUpdate {} else {
                    Button("Build RealLive support") { lib.updateEngine(pull: false) }
                        .help("Builds game_launcher_run from your siglus_rs checkout, for Key's older RealLive / AVG32 games")
                }
            }
            if FileManager.default.fileExists(atPath: lib.engineLog.path) {
                Button("Log") { NSWorkspace.shared.open(lib.engineLog) }
            }
        }
        .onAppear { if lib.engineUpdate == .unknown { lib.checkEngine() } }
    }
}
