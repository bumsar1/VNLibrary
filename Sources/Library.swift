import AppKit
import CoreImage
import SwiftUI

/// How a game is started.
enum LaunchKind: String, Codable, CaseIterable, Identifiable {
    case siglus, macApp, command
    var id: String { rawValue }
    var label: String {
        switch self {
        case .siglus: return "Siglus (siglus_engine)"
        case .macApp: return "Mac app"
        case .command: return "Custom command"
        }
    }
}

struct Game: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var path: String
    var kind: LaunchKind
    var command: String = ""
    var cover: String?            // file name inside the covers folder
    var added = Date()
    var lastPlayed: Date?
    var playSeconds: Double = 0
    var vndb: VNInfo?
    var blurCover: Bool?          // optional so older library files still decode
    var isBlurred: Bool { blurCover ?? false }
    // The user's own tracking (all optional for the same reason).
    var status: PlayStatus?
    var userRating: Int?          // 1–10
    var notes: String?
    var collections: [String]?
    var started: Date?
    var finished: Date?
    var adult: Bool?              // nil = decide from VNDB's sexual-content tags
    var isAdult: Bool { adult ?? !(vndb?.eroTags ?? []).isEmpty }
    /// Added from Discover without a game folder or app yet.
    var installed: Bool { !path.isEmpty }
}

enum SortOrder: String, CaseIterable, Identifiable {
    case recent, name, added, rating
    var id: String { rawValue }
    var label: String {
        switch self {
        case .recent: return "Recently played"
        case .name: return "Name"
        case .added: return "Recently added"
        case .rating: return "My rating"
        }
    }
}

@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published var games: [Game] = []
    @Published var running: [UUID: Date] = [:]
    @Published var alert: String?
    @Published var siglusEngine: String {
        didSet { UserDefaults.standard.set(siglusEngine, forKey: "siglusEngine") }
    }
    @Published var autoVNDB: Bool {
        didSet { UserDefaults.standard.set(autoVNDB, forKey: "autoVNDB") }
    }
    @Published var fetching: Set<UUID> = []
    @Published var showEroTags: Bool {
        didSet { UserDefaults.standard.set(showEroTags, forKey: "showEroTags") }
    }
    /// Discreet mode: every cover blurred, sexual tags and adult games hidden.
    @Published var discreet: Bool {
        didSet { UserDefaults.standard.set(discreet, forKey: "discreet") }
    }
    var syncTasks: [UUID: Task<Void, Never>] = [:]
    /// Blur VNDB images flagged as suggestive (in Discover and galleries).
    @Published var blurSuggestive: Bool {
        didSet { UserDefaults.standard.set(blurSuggestive, forKey: "blurSuggestive") }
    }
    /// VNDB images the user chose to show this session.
    @Published var revealed: Set<String> = []
    @Published var vndbUser: String? {
        didSet { UserDefaults.standard.set(vndbUser, forKey: "vndbUser") }
    }
    @Published var vndbUsername: String? {
        didSet { UserDefaults.standard.set(vndbUsername, forKey: "vndbUsername") }
    }

    static let defaultEngine = "~/siglus_rs/target/release/siglus_engine"

    let supportDir: URL
    let coversDir: URL
    let logsDir: URL
    private var libraryFile: URL { supportDir.appendingPathComponent("library.json") }
    private var images: [String: NSImage] = [:]
    private var processes: [UUID: Process] = [:]
    private var appPIDs: [pid_t: UUID] = [:]

    // Play sessions (see Sessions.swift).
    @Published var sessions: [PlaySession] = []
    var openSessions: [UUID: UUID] = [:]      // game id → its running session
    var lastBeat: [UUID: Date] = [:]
    var heartbeat: Timer?
    var sessionsFile: URL { supportDir.appendingPathComponent("sessions.json") }

    init() {
        // VNLIB_SUPPORT_DIR lets a test run use a throwaway library.
        if let dir = ProcessInfo.processInfo.environment["VNLIB_SUPPORT_DIR"] {
            supportDir = URL(fileURLWithPath: dir)
        } else {
            supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VN Library")
        }
        coversDir = supportDir.appendingPathComponent("covers")
        logsDir = supportDir.appendingPathComponent("logs")
        for d in [coversDir, logsDir] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        siglusEngine = UserDefaults.standard.string(forKey: "siglusEngine") ?? Self.defaultEngine
        autoVNDB = UserDefaults.standard.object(forKey: "autoVNDB") as? Bool ?? true
        showEroTags = UserDefaults.standard.object(forKey: "showEroTags") as? Bool ?? true
        discreet = UserDefaults.standard.bool(forKey: "discreet")
        blurSuggestive = UserDefaults.standard.object(forKey: "blurSuggestive") as? Bool ?? true
        vndbUser = UserDefaults.standard.string(forKey: "vndbUser")
        vndbUsername = UserDefaults.standard.string(forKey: "vndbUsername")
        load()
        loadSessions()
        if ProcessInfo.processInfo.environment["VNLIB_NO_VNDB"] == nil {
            refreshVNDB(onlyOutdated: true)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated {
                guard let self, let id = self.appPIDs.removeValue(forKey: pid) else { return }
                self.finished(id, status: 0, log: nil)
            }
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: libraryFile) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        games = (try? dec.decode([Game].self, from: data)) ?? []
    }

    func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(games) {
            try? data.write(to: libraryFile, options: .atomic)
        }
    }

    func sorted(_ order: SortOrder, filter: String, tag: String? = nil,
                status: PlayStatus? = nil, collection: String? = nil) -> [Game] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        var list = visibleGames
        if let tag { list = list.filter { tags(of: $0).contains(tag) } }
        if let status { list = list.filter { $0.status == status } }
        if let collection { list = list.filter { $0.collections?.contains(collection) ?? false } }
        if !q.isEmpty {
            // Search covers the name, VNDB titles, developers and tags.
            list = list.filter { g in
                ([g.name, g.vndb?.title, g.vndb?.alttitle].compactMap { $0 }
                    + (g.vndb?.developers ?? []) + tags(of: g))
                    .contains { $0.localizedCaseInsensitiveContains(q) }
            }
        }
        switch order {
        case .name:
            return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .added:
            return list.sorted { $0.added > $1.added }
        case .recent:
            return list.sorted { ($0.lastPlayed ?? $0.added) > ($1.lastPlayed ?? $1.added) }
        case .rating:
            return list.sorted { ($0.userRating ?? 0, $1.name) > ($1.userRating ?? 0, $0.name) }
        }
    }

    /// The tags shown for a game, including sexual-content tags when enabled.
    func tags(of game: Game) -> [String] {
        guard let info = game.vndb else { return [] }
        return info.tags + (showEroTags && !discreet ? info.eroTags ?? [] : [])
    }

    func isEroTag(_ tag: String, of game: Game) -> Bool {
        game.vndb?.eroTags?.contains(tag) ?? false
    }

    /// Every tag in the library with how many games carry it, most common first.
    var allTags: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for g in games { for t in tags(of: g) { counts[t, default: 0] += 1 } }
        return counts.map { ($0.key, $0.value) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
    }

    // MARK: Adding

    /// Adds folders or .app bundles. Returns the games that need the user to
    /// fill in a command (nothing launchable was recognised).
    @discardableResult
    func add(urls: [URL]) -> [Game] {
        var unknown: [Game] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            if games.contains(where: { $0.path == path }) { continue }
            var game = detect(url)
            if let src = findCoverSource(for: game) { game.cover = importCover(from: src, id: game.id) }
            games.append(game)
            if game.kind == .command { unknown.append(game) }
            if autoVNDB && ProcessInfo.processInfo.environment["VNLIB_NO_VNDB"] == nil {
                autoMatch(game.id)
            }
        }
        save()
        return unknown
    }

    private func detect(_ url: URL) -> Game {
        let path = url.standardizedFileURL.path
        if url.pathExtension.lowercased() == "app" {
            return Game(name: appName(url), path: path, kind: .macApp)
        }
        let name = url.lastPathComponent
        if isSiglus(url) {
            return Game(name: name, path: path, kind: .siglus)
        }
        // A folder that holds exactly one Mac app is treated as that app.
        let apps = contents(of: url).filter { $0.pathExtension.lowercased() == "app" }
        if apps.count == 1 {
            return Game(name: name, path: apps[0].standardizedFileURL.path, kind: .macApp)
        }
        return Game(name: name, path: path, kind: .command)
    }

    func isSiglus(_ dir: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("Scene.pck").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("Gameexe.dat").path)
    }

    private func appName(_ url: URL) -> String {
        let info = Bundle(url: url)?.infoDictionary
        return (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }

    private func contents(of dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
    }

    // MARK: Covers

    /// Best guess at artwork: conventional cover files first, then the game's
    /// own icon, then the largest image at the top of the folder.
    func findCoverSource(for game: Game) -> URL? {
        let url = URL(fileURLWithPath: game.path)
        if game.kind == .macApp { return url }
        let files = contents(of: url)
        let byName = Dictionary(files.map { ($0.lastPathComponent.lowercased(), $0) },
                                uniquingKeysWith: { a, _ in a })
        for n in ["cover.png", "cover.jpg", "cover.jpeg", "folder.jpg", "thumbnail.png", "icon.png"] {
            if let f = byName[n] { return f }
        }
        if let ico = files.first(where: { ["ico", "icns"].contains($0.pathExtension.lowercased()) }) {
            return ico
        }
        let images = files.filter { ["png", "jpg", "jpeg", "webp"].contains($0.pathExtension.lowercased()) }
        return images.max { size($0) < size($1) }
    }

    private func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// Copies artwork into the library as PNG. `.app` sources use their icon.
    func importCover(from src: URL, id: UUID) -> String? {
        let image: NSImage?
        if src.pathExtension.lowercased() == "app" {
            image = NSWorkspace.shared.icon(forFile: src.path)
        } else {
            image = NSImage(contentsOf: src)
        }
        guard let image, let png = pngData(image) else { return nil }
        let name = "\(id.uuidString)-\(Int(Date().timeIntervalSince1970)).png"
        do {
            try png.write(to: coversDir.appendingPathComponent(name))
            return name
        } catch {
            return nil
        }
    }

    /// Renders the largest representation of an image to PNG (an .ico holds
    /// several sizes; NSImage would otherwise pick a small one).
    private func pngData(_ image: NSImage) -> Data? {
        let best = image.representations.max { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }
        var w = best?.pixelsWide ?? 0, h = best?.pixelsHigh ?? 0
        if w <= 0 || h <= 0 { w = Int(image.size.width); h = Int(image.size.height) }
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        if let best {
            best.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        } else {
            image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    func image(for game: Game) -> NSImage? {
        guard let name = game.cover else { return nil }
        if let img = images[name] { return img }
        let img = NSImage(contentsOf: coversDir.appendingPathComponent(name))
        images[name] = img
        return img
    }

    /// The cover with its pixels blurred, so nothing shows through no matter
    /// how it is drawn.
    func blurredImage(for game: Game) -> NSImage? {
        guard let name = game.cover else { return nil }
        let key = "blur:" + name
        if let img = images[key] { return img }
        guard let src = image(for: game),
              let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        let radius = Double(max(cg.width, cg.height)) * 0.05
        guard let blurred = CIFilter(name: "CIGaussianBlur", parameters: [
            kCIInputImageKey: input.clampedToExtent(), kCIInputRadiusKey: radius,
        ])?.outputImage?.cropped(to: input.extent),
              let out = CIContext().createCGImage(blurred, from: input.extent)
        else { return nil }
        let img = NSImage(cgImage: out, size: src.size)
        images[key] = img
        return img
    }

    func setCover(_ id: UUID, from src: URL?) {
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        let old = games[i].cover
        let source = src ?? findCoverSource(for: games[i])
        games[i].cover = source.flatMap { importCover(from: $0, id: id) }
        if let old, old != games[i].cover {
            try? FileManager.default.removeItem(at: coversDir.appendingPathComponent(old))
            images[old] = nil
            images["blur:" + old] = nil
        }
        save()
    }

    // MARK: VNDB

    /// Takes VNDB's best match for a newly added game. Keeps the user's name;
    /// a wrong guess is fixed with "Fetch from VNDB…".
    func autoMatch(_ id: UUID) {
        guard let game = games.first(where: { $0.id == id }) else { return }
        let query = VNDB.query(from: game.name)
        guard !query.isEmpty else { return }
        fetching.insert(id)
        Task {
            defer { fetching.remove(id) }
            guard let hits = try? await VNDB.search(query, results: 5), let best = hits.first else { return }
            // Installing a game that was added from Discover: give the existing
            // entry (with its status, notes and history) the folder instead.
            // A planned game among VNDB's top hits is strong enough evidence
            // even when the names only loosely match.
            if let planned = games.firstIndex(where: { g in !g.installed && hits.contains { $0.id == g.vndb?.id } }),
               let new = games.firstIndex(where: { $0.id == id }) {
                games[planned].path = games[new].path
                games[planned].kind = games[new].kind
                remove(id)
                return
            }
            guard VNDB.plausible(best, for: query) else { return }
            await apply(best, to: id, rename: false)
        }
    }

    /// Stores VNDB data and downloads the cover.
    func apply(_ result: VNDB.Result, to id: UUID, rename: Bool) async {
        var coverName: String?
        if let url = result.image?.url, let data = try? await VNDB.download(url), NSImage(data: data) != nil {
            let ext = (url as NSString).pathExtension.isEmpty ? "jpg" : (url as NSString).pathExtension
            let name = "\(id.uuidString)-vndb-\(Int(Date().timeIntervalSince1970)).\(ext)"
            if (try? data.write(to: coversDir.appendingPathComponent(name))) != nil { coverName = name }
        }
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        games[i].vndb = result.info
        // VNDB flags suggestive covers; hide those unless the user chose otherwise.
        if result.explicitCover && games[i].blurCover == nil { games[i].blurCover = true }
        if rename { games[i].name = result.title }
        if let coverName {
            if let old = games[i].cover {
                try? FileManager.default.removeItem(at: coversDir.appendingPathComponent(old))
                images[old] = nil
            }
            games[i].cover = coverName
        }
        save()
    }

    /// Fetches VNDB data for every game that has none yet, one at a time.
    func fetchMissingVNDB() {
        let ids = games.filter { $0.vndb == nil }.map(\.id)
        guard !ids.isEmpty else {
            alert = "Every game already has VNDB data."
            return
        }
        Task {
            var missed: [String] = []
            for id in ids {
                guard let game = games.first(where: { $0.id == id }) else { continue }
                fetching.insert(id)
                let query = VNDB.query(from: game.name)
                if let best = try? await VNDB.search(query, results: 1).first, VNDB.plausible(best, for: query) {
                    await apply(best, to: id, rename: false)
                } else {
                    missed.append(game.name)
                }
                fetching.remove(id)
            }
            if !missed.isEmpty {
                alert = "No confident match found for:\n\(missed.joined(separator: "\n"))\n\nRight-click → Fetch from VNDB… to pick one yourself."
            }
        }
    }

    func toggleBlur(_ id: UUID) {
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        games[i].blurCover = !games[i].isBlurred
        save()
    }

    /// Re-reads VNDB data (tags, rating, description) for linked games.
    /// Covers and names are left alone.
    /// `onlyOutdated` limits it to data saved before sexual-content tags were
    /// kept; that runs quietly at launch so older entries catch up by themselves.
    func refreshVNDB(onlyOutdated: Bool = false) {
        let linked = games.compactMap { g in g.vndb.map { (g.id, $0) } }
            .filter { !onlyOutdated || $0.1.eroTags == nil }
            .map { ($0.0, $0.1.id) }
        guard !linked.isEmpty else {
            if !onlyOutdated { alert = "No games are linked to VNDB yet." }
            return
        }
        Task {
            var failed = 0
            for (id, vn) in linked {
                fetching.insert(id)
                if let r = try? await VNDB.fetch(id: vn), let i = games.firstIndex(where: { $0.id == id }) {
                    games[i].vndb = r.info
                } else {
                    failed += 1
                }
                fetching.remove(id)
            }
            save()
            if failed > 0 && !onlyOutdated { alert = "\(failed) game(s) couldn't be updated from VNDB." }
        }
    }

    func forgetVNDB(_ id: UUID) {
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        games[i].vndb = nil
        save()
    }

    // MARK: Editing

    func update(_ game: Game) {
        guard let i = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[i] = game
        save()
    }

    func remove(_ id: UUID) {
        if let cover = games.first(where: { $0.id == id })?.cover {
            try? FileManager.default.removeItem(at: coversDir.appendingPathComponent(cover))
        }
        games.removeAll { $0.id == id }
        save()
        sessions.removeAll { $0.gameID == id }
        saveSessions()
    }

    func exists(_ game: Game) -> Bool {
        game.installed && FileManager.default.fileExists(atPath: game.path)
    }

    /// Adds a VN found in Discover as "Plan to play", with no folder yet.
    /// Returns the existing entry if it's already in the library.
    @discardableResult
    func addFromVNDB(_ result: VNDB.Result) async -> UUID {
        if let existing = games.first(where: { $0.vndb?.id == result.id }) { return existing.id }
        let game = Game(name: result.title, path: "", kind: .command, status: .planned)
        games.append(game)
        save()
        await apply(result, to: game.id, rename: false)
        scheduleVNDBSync(game.id)
        return game.id
    }

    /// Links a game to its folder or app and works out how to launch it.
    func detectKind(of url: URL) -> LaunchKind {
        if url.pathExtension.lowercased() == "app" { return .macApp }
        return isSiglus(url) ? .siglus : .command
    }

    var enginePath: String { (siglusEngine as NSString).expandingTildeInPath }
    var engineFound: Bool { FileManager.default.isExecutableFile(atPath: enginePath) }

    // MARK: Launching

    func launch(_ game: Game) {
        guard running[game.id] == nil else { return }
        guard game.installed else {
            alert = "\(game.name) isn't installed yet. Right-click → Edit and choose its game folder or app."
            return
        }
        guard exists(game) else {
            alert = "\(game.name) wasn't found:\n\(game.path)\n\nDid you move the folder? Fix the path under Edit."
            return
        }
        switch game.kind {
        case .macApp:
            let cfg = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: game.path), configuration: cfg) { app, error in
                let pid = app?.processIdentifier
                let message = error?.localizedDescription
                Task { @MainActor in
                    if let pid {
                        self.appPIDs[pid] = game.id
                        self.started(game.id)
                    } else {
                        self.alert = "Couldn't start \(game.name): \(message ?? "unknown error")"
                    }
                }
            }
        case .siglus:
            guard engineFound else {
                alert = "siglus_engine wasn't found:\n\(enginePath)\n\nSet the right path in Settings (the gear icon)."
                return
            }
            run(game, executable: enginePath, arguments: ["--project-dir", game.path])
        case .command:
            let cmd = game.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cmd.isEmpty else {
                alert = "\(game.name) has no command yet. Right-click → Edit to set how the game starts."
                return
            }
            run(game, executable: "/bin/zsh", arguments: ["-lc", cmd])
        }
    }

    private func logURL(_ game: Game) -> URL {
        logsDir.appendingPathComponent("\(game.id.uuidString).log")
    }

    private func run(_ game: Game, executable: String, arguments: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: game.path, isDirectory: &isDir), isDir.boolValue {
            p.currentDirectoryURL = URL(fileURLWithPath: game.path)
        }
        var env = ProcessInfo.processInfo.environment
        env["GAME_DIR"] = game.path
        p.environment = env
        let log = logURL(game)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let fh = try? FileHandle(forWritingTo: log) {
            p.standardOutput = fh
            p.standardError = fh
        }
        let id = game.id
        p.terminationHandler = { proc in
            let status = proc.terminationStatus
            Task { @MainActor in self.finished(id, status: status, log: log) }
        }
        do {
            try p.run()
            processes[id] = p
            started(id)
        } catch {
            alert = "Couldn't start \(game.name): \(error.localizedDescription)"
        }
    }

    private func started(_ id: UUID) {
        running[id] = Date()
        if let i = games.firstIndex(where: { $0.id == id }) {
            games[i].lastPlayed = Date()
            save()
        }
        beginSession(id)
        markPlayingIfNew(id)
    }

    private func finished(_ id: UUID, status: Int32, log: URL?) {
        processes[id] = nil
        guard let start = running.removeValue(forKey: id) else { return }
        let elapsed = Date().timeIntervalSince(start)
        endSession(id)     // adds the active time to the game's total
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        // A quick non-zero exit means the game never really ran: show why.
        if status != 0, elapsed < 10 {
            var tail = ""
            if let log, let text = try? String(contentsOf: log, encoding: .utf8) {
                tail = text.split(separator: "\n").suffix(8).joined(separator: "\n")
            }
            alert = "\(games[i].name) quit with an error (code \(status)).\n\n\(tail)"
        }
    }

    func stop(_ id: UUID) {
        processes[id]?.terminate()
        if let pid = appPIDs.first(where: { $0.value == id })?.key {
            NSRunningApplication(processIdentifier: pid)?.terminate()
        }
    }

    func showLog(_ game: Game) {
        let log = logURL(game)
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.open(log)
        } else {
            alert = "There's no log for \(game.name) yet."
        }
    }
}

enum Format {
    static func playtime(_ seconds: Double) -> String {
        let m = Int(seconds / 60)
        if m < 1 { return "under 1 min" }
        if m < 60 { return "\(m) min" }
        return "\(m / 60) h \(m % 60) min"
    }

    static func lastPlayed(_ date: Date?) -> String {
        guard let date else { return "Not played yet" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "en_US")
        f.unitsStyle = .full
        return "Played " + f.localizedString(for: date, relativeTo: Date())
    }
}
