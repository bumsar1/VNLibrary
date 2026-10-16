import AppKit

/// Save backups, the watched folder and disk usage.

struct SaveBackup: Identifiable {
    let url: URL
    let date: Date
    let bytes: Int64
    var id: URL { url }
}

extension Library {
    // MARK: Save backups

    static let keptBackups = 15

    /// The game's save folder: the one set under Edit, else a usual name
    /// inside the game folder (Siglus and KiriKiri use "savedata").
    func saveFolder(for game: Game) -> URL? {
        if let s = game.saveFolder, !s.isEmpty { return URL(fileURLWithPath: s) }
        // KiriKiri Player keeps saves in its own folder; the game folder is never written to.
        if game.kind == .kirikiri, let p = kirikiriPaths(for: game) { return URL(fileURLWithPath: p.saves) }
        guard game.installed, game.kind != .macApp else { return nil }
        let base = URL(fileURLWithPath: game.path)
        for n in ["savedata", "SaveData", "save", "Save", "saves", "Saves", "savedat"] {
            var isDir: ObjCBool = false
            let u = base.appendingPathComponent(n)
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue { return u }
        }
        return nil
    }

    func backupsDir(_ game: Game) -> URL {
        supportDir.appendingPathComponent("backups/\(game.id.uuidString)")
    }

    func backups(for game: Game) -> [SaveBackup] {
        let dir = backupsDir(game)
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey],
                                                                   options: [.skipsHiddenFiles])) ?? []
        return items.map { u in
            SaveBackup(url: u, date: (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast,
                       bytes: Self.size(of: u))
        }
        .sorted { $0.date > $1.date }
    }

    /// Copies the save folder aside, unless nothing changed since the last
    /// copy. Runs before every launch; keeps the newest few.
    @discardableResult
    func backupSaves(_ game: Game, force: Bool = false) -> Bool {
        guard let src = saveFolder(for: game), FileManager.default.fileExists(atPath: src.path) else { return false }
        let fingerprint = Self.fingerprint(of: src)
        let dir = backupsDir(game)
        let stamp = dir.appendingPathComponent(".last")
        if !force, (try? String(contentsOf: stamp, encoding: .utf8)) == fingerprint { return false }
        guard Self.size(of: src) < 2 << 30 else { return false }     // not for multi-GB folders
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let dest = dir.appendingPathComponent(f.string(from: Date()))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: src, to: dest)
            try fingerprint.write(to: stamp, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        for old in backups(for: game).dropFirst(Self.keptBackups) {
            try? FileManager.default.removeItem(at: old.url)
        }
        return true
    }

    /// Puts a backup back. The current saves are backed up first, so a
    /// restore can itself be undone.
    func restore(_ backup: SaveBackup, for game: Game) {
        guard running[game.id] == nil else { alert = "Quit the game before restoring a backup."; return }
        guard let dest = saveFolder(for: game) else { alert = "No save folder set for \(game.name)."; return }
        backupSaves(game, force: true)
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: backup.url, to: dest)
            alert = "Restored the saves from \(Format.date(backup.date)) \(Format.time(backup.date)). Your previous saves were backed up first."
        } catch {
            alert = "Couldn't restore: \(error.localizedDescription)"
        }
    }

    /// File count, total size and newest change: enough to tell "unchanged".
    private static func fingerprint(of dir: URL) -> String {
        var count = 0, total: Int64 = 0
        var newest = Date.distantPast
        if let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) {
            for case let u as URL in e {
                let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                count += 1
                total += Int64(v?.fileSize ?? 0)
                if let m = v?.contentModificationDate, m > newest { newest = m }
            }
        }
        return "\(count)-\(total)-\(newest.timeIntervalSince1970)"
    }

    nonisolated static func size(of url: URL) -> Int64 {
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) {
            for case let u as URL in e {
                let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
                total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
            }
        } else if let v = try? url.resourceValues(forKeys: [.fileSizeKey]) {
            total = Int64(v.fileSize ?? 0)
        }
        return total
    }

    // MARK: Watched folder

    /// Adds new game folders and apps that show up in the watched folder.
    /// Games removed from the library are remembered and not added again.
    func scanWatchFolder() {
        guard loaded, let dir = watchFolder, !dir.isEmpty else { return }
        let base = URL(fileURLWithPath: dir)
        let items = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey],
                                                                   options: [.skipsHiddenFiles])) ?? []
        let known = Set(games.map(\.path).filter { !$0.isEmpty })
        let ignored = Set(UserDefaults.standard.stringArray(forKey: "ignoredPaths") ?? [])
        let fresh = items.filter { u in
            let p = u.standardizedFileURL.path
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            // A known game may live in a sub-folder (its .app); count the parent as known too.
            let covered = known.contains(p) || known.contains { $0.hasPrefix(p + "/") }
            return isDir && !covered && !ignored.contains(p)
        }
        if !fresh.isEmpty { add(urls: fresh) }
    }

    func rememberRemoved(_ path: String) {
        guard let dir = watchFolder, !dir.isEmpty, !path.isEmpty, path.hasPrefix(dir) else { return }
        // Remember the top-level item inside the watched folder.
        let rel = path.dropFirst(dir.count).split(separator: "/").first.map(String.init) ?? ""
        guard !rel.isEmpty else { return }
        var ignored = UserDefaults.standard.stringArray(forKey: "ignoredPaths") ?? []
        let top = URL(fileURLWithPath: dir).appendingPathComponent(rel).standardizedFileURL.path
        if !ignored.contains(top) { ignored.append(top) }
        UserDefaults.standard.set(ignored, forKey: "ignoredPaths")
    }

    // MARK: Disk usage

    /// Measures installed games' sizes in the background.
    func measureSizes(force: Bool = false) {
        let todo = games.filter { $0.installed && (force || $0.sizeBytes == nil) }.map { ($0.id, $0.path) }
        guard !todo.isEmpty else { return }
        Task.detached {
            for (id, path) in todo where FileManager.default.fileExists(atPath: path) {
                let bytes = Library.size(of: URL(fileURLWithPath: path))
                await MainActor.run {
                    if let i = self.games.firstIndex(where: { $0.id == id }) { self.games[i].sizeBytes = bytes }
                }
            }
            await MainActor.run { self.save() }
        }
    }

    /// Moves a game's files to the Trash and keeps its library entry (status,
    /// notes, play time) as "Not installed".
    func trashFiles(_ id: UUID) {
        guard let i = games.firstIndex(where: { $0.id == id }), games[i].installed else { return }
        guard running[id] == nil else { alert = "Quit the game first."; return }
        let url = URL(fileURLWithPath: games[i].path)
        backupSaves(games[i])
        NSWorkspace.shared.recycle([url]) { _, error in
            Task { @MainActor in
                if let error {
                    self.alert = "Couldn't move it to the Trash: \(error.localizedDescription)"
                    return
                }
                guard let i = self.games.firstIndex(where: { $0.id == id }) else { return }
                self.rememberRemoved(self.games[i].path)
                self.games[i].path = ""
                self.games[i].sizeBytes = nil
                self.save()
            }
        }
    }

    var totalInstalledBytes: Int64 { games.filter { exists($0) }.reduce(0) { $0 + ($1.sizeBytes ?? 0) } }
}

enum Bytes {
    static func format(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}

import SwiftUI

/// Lists a game's save backups, with restore.
struct BackupsSheet: View {
    @EnvironmentObject var lib: Library
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var list: [SaveBackup] = []
    @State private var confirm: SaveBackup?

    var body: some View {
        let game = lib.games.first { $0.id == id }
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Backups").font(.system(size: 18, weight: .bold))
            if let game {
                Text(lib.saveFolder(for: game).map { "Saves: \($0.path)" } ?? "No save folder found. Choose it under Edit → Saves.")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                Text("A copy is made automatically before each session when the saves have changed. The newest \(Library.keptBackups) are kept.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if list.isEmpty {
                Text("No backups yet.").foregroundStyle(.secondary).padding(.vertical, 20)
            } else {
                List(list) { b in
                    HStack {
                        Text("\(Format.day(b.date)) \(Format.time(b.date))")
                        Spacer()
                        Text(Bytes.format(b.bytes)).foregroundStyle(.secondary)
                        Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([b.url]) }
                        Button("Restore") { confirm = b }
                    }
                }
                .frame(height: 260)
            }
            HStack {
                if let game {
                    Button("Back Up Now") {
                        if !lib.backupSaves(game, force: true) { lib.alert = "Nothing to back up — no save folder found." }
                        list = lib.backups(for: game)
                    }
                    .disabled(lib.saveFolder(for: game) == nil)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear { if let game { list = lib.backups(for: game) } }
        .confirmationDialog("Restore this backup?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Restore", role: .destructive) {
                if let b = confirm, let game { lib.restore(b, for: game); list = lib.backups(for: game) }
            }
        } message: {
            Text("Your current saves are backed up first, so you can go back.")
        }
    }
}
