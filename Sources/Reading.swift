import Foundation

/// Characters read, from the text Meikipop recognises on screen.
///
/// Meikipop appends one JSON line per OCR frame to
/// ~/Library/Application Support/meikipop/read-log/YYYY-MM-DD.jsonl:
///   {"t": <unix time>, "pid": <int|null>, "lines": ["…", …]}
/// Frames are matched to the game whose play session was running at that
/// time, and every line is counted once per game:
/// - text drawn letter by letter only counts in its finished form,
/// - a line seen again (re-reading, the backlog, a menu label) counts once,
/// - lines that differ by an OCR slip of a character or two count once.
enum ReadLog {
    static var folder: URL {
        if let o = ProcessInfo.processInfo.environment["VNLIB_READLOG"] { return URL(fileURLWithPath: o) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/meikipop/read-log")
    }

    struct Frame: Decodable {
        let t: Double
        let pid: Int?
        let lines: [String]
    }

    /// Keeps the characters worth counting: kana, kanji and letters/digits;
    /// drops punctuation, brackets and spaces (so 「…」 and line breaks don't
    /// make the same sentence look different).
    static func normalize(_ s: String) -> String {
        String(s.unicodeScalars.filter { u in
            switch u.value {
            case 0x3041...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF,    // hiragana, katakana
                 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF,    // kanji
                 0x3005, 0x3006, 0x30FC,                               // 々 〆 ー
                 0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF41...0xFF5A:    // full-width alphanumerics
                return true
            default:
                return CharacterSet.alphanumerics.contains(u) && u.isASCII
            }
        }.map(Character.init))
    }

    /// Stable 64-bit FNV-1a (Swift's own hash changes every launch).
    static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    /// Similarity 0…1 from edit distance, for catching OCR slips.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        if x.isEmpty || y.isEmpty { return 0 }
        if abs(x.count - y.count) * 5 > max(x.count, y.count) { return 0 }    // >20% length difference
        var prev = Array(0...y.count), cur = Array(repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }
}

/// Per-game dedup state: lines still on screen (may still be growing) and
/// what has been counted.
final class ReadTracker {
    /// `text` is normalised (for matching and counting); `raw` is what was on screen.
    struct Open { var text: String; var raw: String; var firstSeen: Double; var lastSeen: Double }
    /// A line that was counted, to keep as readable text.
    struct Counted { let raw: String; let chars: Int; let t: Double }
    var open: [Open] = []
    var seen: Set<UInt64>
    var blacklist: Set<UInt64> = []    // sentences the user said never to count in this game
    var recent: [String] = []       // last committed lines, for fuzzy matching

    init(seen: Set<UInt64>) { self.seen = seen }

    /// Feeds one frame; returns characters newly counted.
    func feed(_ lines: [String], at t: Double, filter: ReadFilter = ReadFilter()) -> [Counted] {
        for raw in lines {
            let n = ReadLog.normalize(raw)
            guard n.count >= 2, !filter.ignores(raw: raw, normalized: n) else { continue }
            if let i = open.firstIndex(where: { n.hasPrefix($0.text) }) {
                open[i] = Open(text: n, raw: raw, firstSeen: open[i].firstSeen, lastSeen: t)   // still typing out: keep the longer
            } else if let i = open.firstIndex(where: { $0.text.hasPrefix(n) }) {
                open[i].lastSeen = t                           // a partial frame of a line we have
            } else if let i = open.firstIndex(where: { ReadLog.similarity($0.text, n) >= 0.9 }) {
                if n.count > open[i].text.count { open[i].text = n; open[i].raw = raw }
                open[i].lastSeen = t
            } else {
                open.append(Open(text: n, raw: raw, firstSeen: t, lastSeen: t))
            }
        }
        // A line gone from the screen for 15 s is finished.
        return commit { $0.lastSeen < t - 15 }
    }

    /// Counts everything still open (the session ended).
    func flush() -> [Counted] { commit { _ in true } }

    private func commit(_ done: (Open) -> Bool) -> [Counted] {
        var added: [Counted] = []
        let finished = open.filter(done)
        open.removeAll(where: done)
        for o in finished {
            let h = ReadLog.hash(o.text)
            guard !seen.contains(h), !blacklist.contains(h) else { continue }
            seen.insert(h)
            if recent.suffix(150).contains(where: { ReadLog.similarity($0, o.text) >= 0.88 }) { continue }
            recent.append(o.text)
            if recent.count > 400 { recent.removeFirst(recent.count - 400) }
            added.append(Counted(raw: o.raw.trimmingCharacters(in: .whitespacesAndNewlines), chars: o.text.count, t: o.firstSeen))
        }
        return added
    }
}

extension Library {
    private var readingDir: URL { supportDir.appendingPathComponent("reading") }
    private var offsetsFile: URL { readingDir.appendingPathComponent("offsets.json") }

    private func seenFile(_ id: UUID) -> URL { readingDir.appendingPathComponent("\(id.uuidString).seen") }

    func tracker(for id: UUID) -> ReadTracker {
        if let t = readTrackers[id] { return t }
        var seen = Set<UInt64>()
        if let data = try? Data(contentsOf: seenFile(id)) {
            data.withUnsafeBytes { raw in
                for i in stride(from: 0, to: raw.count - 7, by: 8) { seen.insert(raw.loadUnaligned(fromByteOffset: i, as: UInt64.self)) }
            }
        }
        let t = ReadTracker(seen: seen)
        t.blacklist = Set(blacklist(game: id).map { ReadLog.hash($0.norm) })
        readTrackers[id] = t
        return t
    }

    private func saveSeen(_ id: UUID) {
        guard let t = readTrackers[id] else { return }
        var data = Data(capacity: t.seen.count * 8)
        for h in t.seen { withUnsafeBytes(of: h) { data.append(contentsOf: $0) } }
        try? FileManager.default.createDirectory(at: readingDir, withIntermediateDirectories: true)
        try? data.write(to: seenFile(id), options: .atomic)
    }

    /// Reads what Meikipop logged since last time and counts it. Runs on
    /// every session heartbeat, when a session ends and at start-up.
    func processReadLog() {
        let dir = ReadLog.folder
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "jsonl" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }),
              !files.isEmpty else { return }
        var offsets = (try? JSONDecoder().decode([String: UInt64].self, from: Data(contentsOf: offsetsFile))) ?? [:]
        var touched = Set<UUID>()
        let dec = JSONDecoder()
        let filter = ReadFilter.current()
        let now = Date().timeIntervalSince1970

        for file in files {
            let name = file.lastPathComponent
            guard let h = try? FileHandle(forReadingFrom: file) else { continue }
            let start = offsets[name] ?? 0
            try? h.seek(toOffset: start)
            let data = h.readDataToEndOfFile()
            try? h.close()
            // Only whole lines; a line Meikipop is still writing waits for next time.
            guard let lastNL = data.lastIndex(of: 0x0A) else { continue }
            let chunk = data[data.startIndex...lastNL]
            offsets[name] = start + UInt64(chunk.count)
            for line in chunk.split(separator: 0x0A) {
                guard let f = try? dec.decode(ReadLog.Frame.self, from: Data(line)),
                      let session = sessionIndex(at: f.t, now: now) else { continue }
                // Text from another app (a browser you switched to) doesn't count. Frames
                // without a pid, or sessions from before pids were recorded, are trusted.
                if let pid = f.pid, let pids = sessions[session].pids, !pids.isEmpty, !pids.contains(pid) { continue }
                let gid = sessions[session].gameID
                let added = tracker(for: gid).feed(f.lines, at: f.t, filter: filter)
                if !added.isEmpty { credit(added, game: gid, session: session) }
                touched.insert(gid)
            }
        }
        // Games no longer running: everything still on screen is finished.
        for gid in Set(readTrackers.keys) where openSessions[gid] == nil {
            let added = readTrackers[gid]!.flush()
            // Lines finished at the end are credited to the session they were first seen in.
            if let first = added.first, let s = sessionIndex(at: first.t, now: now) ?? sessions.lastIndex(where: { $0.gameID == gid }) {
                credit(added, game: gid, session: s)
            }
            touched.insert(gid)
        }
        for gid in touched { saveSeen(gid) }
        try? FileManager.default.createDirectory(at: readingDir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(offsets) { try? d.write(to: offsetsFile, options: .atomic) }
        if !touched.isEmpty { save(); saveSessions() }
    }

    /// The play session running at time t (a minute of slack at the end,
    /// since the session end only moves every heartbeat).
    private func sessionIndex(at t: Double, now: Double) -> Int? {
        let date = Date(timeIntervalSince1970: t)
        return sessions.lastIndex { s in
            let end = openSessions[s.gameID] == s.id ? Date(timeIntervalSince1970: now) : s.end.addingTimeInterval(60)
            return s.start <= date && date <= end
        }
    }

    private func credit(_ lines: [ReadTracker.Counted], game: UUID, session: Int) {
        let chars = lines.reduce(0) { $0 + $1.chars }
        sessions[session].chars = (sessions[session].chars ?? 0) + chars
        if let i = games.firstIndex(where: { $0.id == game }) { games[i].readChars = (games[i].readChars ?? 0) + chars }
        let sid = sessions[session].id
        appendReadLines(lines.map { ReadLine(session: sid, t: $0.t, text: $0.raw, chars: $0.chars) }, game: game)
        lastLinesCache[game] = Array(((lastLinesCache[game] ?? lastLines(game)) + lines.map(\.raw)).suffix(3))
        checkFinished(game)
    }

    /// The last few lines read in a game, for "where you left off".
    func lastLines(_ game: UUID) -> [String] {
        if let c = lastLinesCache[game] { return c }
        let l = Array(readLines(game: game).suffix(3).map(\.text))
        lastLinesCache[game] = l
        return l
    }

    /// Offers to mark a game finished once all its routes are ticked or about
    /// 90% of its text (by jiten.moe's count) has been read. Asked once.
    func checkFinished(_ id: UUID) {
        guard finishPrompt == nil, let g = games.first(where: { $0.id == id }),
              g.status != .finished, g.finishAsked != true else { return }
        let routesDone = (g.routes?.isEmpty == false) && g.routes!.allSatisfy { g.routesDone?.contains($0.id) ?? false }
        let mostlyRead = (g.jiten?.characters ?? 0) > 0 && Double(g.readChars ?? 0) >= 0.9 * Double(g.jiten!.characters)
        if routesDone || mostlyRead { finishPrompt = id }
    }

    func answerFinishPrompt(_ finished: Bool) {
        guard let id = finishPrompt, let i = games.firstIndex(where: { $0.id == id }) else { finishPrompt = nil; return }
        finishPrompt = nil
        games[i].finishAsked = true
        save()
        if finished { setStatus(id, .finished) }
    }

    // MARK: Text kept for reviewing

    private func linesFile(_ id: UUID) -> URL { readingDir.appendingPathComponent("\(id.uuidString).lines.jsonl") }

    /// One JSON line per counted line, appended, so long games stay cheap to save.
    private func appendReadLines(_ lines: [ReadLine], game: UUID) {
        guard !lines.isEmpty else { return }
        try? FileManager.default.createDirectory(at: readingDir, withIntermediateDirectories: true)
        let url = linesFile(game)
        var data = Data()
        for l in lines {
            if let d = try? JSONEncoder().encode(l) { data.append(d); data.append(0x0A) }
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    func readLines(game: UUID) -> [ReadLine] {
        guard let data = try? Data(contentsOf: linesFile(game)) else { return [] }
        let dec = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { try? dec.decode(ReadLine.self, from: Data($0)) }
    }

    /// Takes lines off the count. Deleting forgets them, so the same text
    /// counts again if it comes up later (OCR caught it at a bad moment);
    /// blacklisting means that exact sentence never counts in this game.
    func deleteReadLines(_ ids: Set<UUID>, game: UUID, blacklist: Bool = false) {
        let all = readLines(game: game)
        let gone = all.filter { ids.contains($0.id) }
        guard !gone.isEmpty else { return }
        let t = tracker(for: game)
        for l in gone {
            let n = ReadLog.normalize(l.text)
            let h = ReadLog.hash(n)
            if blacklist {
                t.blacklist.insert(h)
            } else {
                t.seen.remove(h)
                t.recent.removeAll { $0 == n }
            }
        }
        if blacklist {
            var list = self.blacklist(game: game)
            for l in gone where !list.contains(where: { $0.norm == ReadLog.normalize(l.text) }) {
                list.append(BlacklistEntry(raw: l.text, norm: ReadLog.normalize(l.text)))
            }
            saveBlacklist(list, game: game)
        }
        saveSeen(game)
        for l in gone {
            if let s = sessions.firstIndex(where: { $0.id == l.session }) {
                sessions[s].chars = max(0, (sessions[s].chars ?? 0) - l.chars)
            }
        }
        if let i = games.firstIndex(where: { $0.id == game }) {
            games[i].readChars = max(0, (games[i].readChars ?? 0) - gone.reduce(0) { $0 + $1.chars })
        }
        lastLinesCache[game] = nil
        let keep = all.filter { !ids.contains($0.id) }
        var data = Data()
        for l in keep { if let d = try? JSONEncoder().encode(l) { data.append(d); data.append(0x0A) } }
        try? data.write(to: linesFile(game), options: .atomic)
        save()
        saveSessions()
    }

    private func blacklistFile(_ id: UUID) -> URL { readingDir.appendingPathComponent("\(id.uuidString).blacklist.json") }

    func blacklist(game: UUID) -> [BlacklistEntry] {
        (try? JSONDecoder().decode([BlacklistEntry].self, from: Data(contentsOf: blacklistFile(game)))) ?? []
    }

    private func saveBlacklist(_ list: [BlacklistEntry], game: UUID) {
        try? FileManager.default.createDirectory(at: readingDir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(list) { try? d.write(to: blacklistFile(game), options: .atomic) }
    }

    /// Lets a blacklisted sentence count again from now on.
    func unblacklist(_ entry: BlacklistEntry, game: UUID) {
        saveBlacklist(blacklist(game: game).filter { $0.norm != entry.norm }, game: game)
        let h = ReadLog.hash(entry.norm)
        tracker(for: game).blacklist.remove(h)
        tracker(for: game).seen.remove(h)
        saveSeen(game)
    }

    /// Takes popup text that was counted before the filter knew about it
    /// back off the count. Runs once.
    func purgePopupText() {
        let key = "purgedPopupText1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        for g in games {
            let ids = Set(readLines(game: g.id).filter { ReadFilter.looksLikePopup($0.text) }.map(\.id))
            if !ids.isEmpty { deleteReadLines(ids, game: g.id) }
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    func resetReading(_ id: UUID) {
        readTrackers[id] = nil
        lastLinesCache[id] = nil
        try? FileManager.default.removeItem(at: seenFile(id))
        try? FileManager.default.removeItem(at: linesFile(id))
        if let i = games.firstIndex(where: { $0.id == id }) { games[i].readChars = nil }
        for i in sessions.indices where sessions[i].gameID == id { sessions[i].chars = nil }
        save()
        saveSessions()
    }

    /// Characters per hour of play, over the sessions where text was logged.
    func readingSpeed(_ id: UUID? = nil) -> Double? {
        let s = sessions.filter { ($0.chars ?? 0) > 0 && (id == nil || $0.gameID == id) }
        let secs = s.reduce(0) { $0 + $1.seconds }
        guard secs > 600 else { return nil }
        return Double(s.reduce(0) { $0 + ($1.chars ?? 0) }) / (secs / 3600)
    }

    func charsRead(since date: Date) -> Int {
        sessions.filter { $0.start >= date }.reduce(0) { $0 + ($1.chars ?? 0) }
    }
}

/// A counted line of text, kept so it can be read back and cleaned up.
struct ReadLine: Codable, Identifiable, Hashable {
    var id = UUID()
    let session: UUID
    let t: Double
    let text: String
    let chars: Int
}

import SwiftUI

/// The text counted for a game or one session: read it back, search it,
/// and delete lines that shouldn't count.
struct ReadTextSheet: View {
    @EnvironmentObject var lib: Library
    @Environment(\.dismiss) private var dismiss
    let game: UUID
    let session: UUID?

    @State private var lines: [ReadLine] = []
    @State private var selection = Set<UUID>()
    @State private var search = ""
    @State private var confirm: Action?
    @State private var showBlacklist = false
    @State private var blacklisted: [BlacklistEntry] = []

    enum Action: Identifiable { case delete, blacklist; var id: Self { self } }

    private var shown: [ReadLine] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return lines.filter { (session == nil || $0.session == session) && (q.isEmpty || $0.text.localizedCaseInsensitiveContains(q)) }
    }

    var body: some View {
        let list = shown
        let g = lib.games.first { $0.id == game }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Text read").font(.system(size: 18, weight: .bold))
                    Text([g.map(lib.displayName), sessionLabel].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(list.count) lines · \(Count.short(list.reduce(0) { $0 + $1.chars })) chars")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Search the text", text: $search).textFieldStyle(.roundedBorder)
                Button(showBlacklist ? "Text" : "Blacklist (\(blacklisted.count))") { showBlacklist.toggle() }
                Menu("Select") {
                    Button("Lines Under 4 Characters") { selection = Set(list.filter { $0.chars < 4 }.map(\.id)) }
                    Button("Lines Matching Search") { selection = Set(list.map(\.id)) }
                        .disabled(search.isEmpty)
                    Button("None") { selection = [] }
                }
                .fixedSize()
            }
            if showBlacklist {
                blacklistView
            } else if list.isEmpty {
                Text(lines.isEmpty ? "No text kept yet. It's saved from now on while you play with Meikipop open."
                                   : "No lines match.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 200)
            } else {
                List(list, selection: $selection) { l in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(time(l.t)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            .frame(width: session == nil ? 92 : 40, alignment: .leading)
                        Text(l.text).font(.system(size: 14)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(l.chars)").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(l.id)
                }
                .frame(minHeight: 360)
                .onDeleteCommand { if !selection.isEmpty { confirm = .delete } }
            }
            HStack {
                Text("Delete: off the count, but it can count again later. Blacklist: never counts again in this game.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if !showBlacklist {
                    Button("Delete") { confirm = .delete }
                        .disabled(selection.isEmpty)
                    Button("Blacklist", role: .destructive) { confirm = .blacklist }
                        .disabled(selection.isEmpty)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 760, height: 600)
        .onAppear(perform: reload)
        .confirmationDialog(confirm == .blacklist ? "Blacklist \(selection.count) sentence\(selection.count == 1 ? "" : "s")?"
                                                  : "Delete \(selection.count) line\(selection.count == 1 ? "" : "s")?",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            presenting: confirm) { action in
            Button(action == .blacklist ? "Blacklist" : "Delete", role: .destructive) {
                lib.deleteReadLines(selection, game: game, blacklist: action == .blacklist)
                selection = []
                reload()
            }
        } message: { action in
            let chars = lines.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.chars }
            Text(action == .blacklist
                 ? "\(Count.short(chars)) characters are subtracted, and the same sentence won't count again in this game. You can undo it under Blacklist."
                 : "\(Count.short(chars)) characters are subtracted. If the same text shows up again later, it counts again.")
        }
    }

    private func reload() {
        lines = lib.readLines(game: game)
        blacklisted = lib.blacklist(game: game)
    }

    @ViewBuilder
    private var blacklistView: some View {
        if blacklisted.isEmpty {
            Text("Nothing blacklisted. Select lines and choose Blacklist to stop sentences like menu labels from counting.")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 200)
        } else {
            List(blacklisted) { b in
                HStack {
                    Text(b.raw).font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Allow Again") {
                        lib.unblacklist(b, game: game)
                        reload()
                    }
                }
            }
            .frame(minHeight: 360)
        }
    }

    private var sessionLabel: String? {
        guard let session, let s = lib.sessions.first(where: { $0.id == session }) else { return nil }
        var label = "\(Format.day(s.start)) \(Format.time(s.start))–\(Format.time(s.end))"
        // Reading speed over the session's active time.
        if let c = s.chars, c > 0, s.seconds >= 300 { label += " · \(Count.short(Int(Double(c) / (s.seconds / 3600)))) chars/h" }
        return label
    }

    private func time(_ t: Double) -> String {
        let d = Date(timeIntervalSince1970: t)
        return session == nil ? "\(Format.date(d).prefix(6)) \(Format.time(d))" : Format.time(d)
    }
}

struct BlacklistEntry: Codable, Hashable, Identifiable {
    let raw: String
    let norm: String
    var id: String { norm }
}

/// Lines that never count in any game: menu and button words every VN has,
/// and (optionally) lines without any Japanese in them.
struct ReadFilter {
    static let defaultWords = """
    セーブ ロード クイックセーブ クイックロード Qセーブ Qロード オート オートモード スキップ 既読スキップ 未読スキップ
    ログ バックログ 履歴 メッセージ履歴 コンフィグ 設定 環境設定 システム オプション メニュー タイトル タイトルへ タイトルに戻る
    ゲーム終了 キャンセル ボイス 音量 ウィンドウ 全画面 フルスクリーン
    ヘルプ はじめから 始めから つづきから 続きから おまけ 鑑賞 回想 ギャラリー CGモード シーン回想 音楽鑑賞
    スクリーンショット 上書きしますか ページ データ NODATA NO DATA
    SAVE LOAD QSAVE QLOAD QUICKSAVE QUICKLOAD AUTO SKIP LOG BACKLOG BACK CONFIG SYSTEM OPTION OPTIONS MENU TITLE
    EXIT QUIT CLOSE VOICE LOCK RECORD TWITTER HIDE NEXT PREV START CONTINUE EXTRA EXTRAS GALLERY YES NO OK CANCEL
    NEW GAME NEWGAME SETTINGS HELP FULLSCREEN WINDOW SCREENSHOT
    """.split(whereSeparator: \.isWhitespace).map(String.init)

    var words: Set<String> = []
    var japaneseOnly = true

    static func current() -> ReadFilter {
        let d = UserDefaults.standard
        // A list saved without being edited (an older Done button did that) just
        // freezes old defaults; drop it so improvements to the defaults apply.
        if d.object(forKey: "readIgnoreWords") != nil && !d.bool(forKey: "readIgnoreWordsEdited") {
            d.removeObject(forKey: "readIgnoreWords")
        }
        let list = d.stringArray(forKey: "readIgnoreWords") ?? defaultWords
        return ReadFilter(words: Set(list.map { ReadLog.normalize($0).uppercased() }.filter { !$0.isEmpty }),
                          japaneseOnly: d.object(forKey: "readJapaneseOnly") as? Bool ?? true)
    }

    /// Meikipop's own dictionary popup, read by the OCR when it sits over the
    /// game: readings in [ ], "Add to Anki", and runs of English glosses.
    static func looksLikePopup(_ raw: String) -> Bool {
        if raw.contains("[") || raw.contains("]") || raw.localizedCaseInsensitiveContains("anki") { return true }
        if raw.contains("】") != raw.contains("【") { return true }
        let latin = raw.unicodeScalars.filter { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }.count
        let letters = raw.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        return latin >= 6 && Double(latin) >= Double(letters) * 0.2
    }

    func ignores(raw: String, normalized n: String) -> Bool {
        if Self.looksLikePopup(raw) { return true }
        // Text in dialogue brackets is speech: 「はい」 always counts, whatever the list says.
        if raw.contains(where: { "「」『』（）".contains($0) }) { return false }
        // A line without kana or kanji is a button, a date or a number.
        if japaneseOnly && !n.unicodeScalars.contains(where: { (0x3041...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }) {
            return true
        }
        if words.contains(n.uppercased()) { return true }
        // A row of menu words ("QSAVE QLOAD SAVE LOAD AUTO") counts as menu too.
        let tokens = raw.split(whereSeparator: { $0.isWhitespace || "・|/／｜".contains($0) })
            .map { ReadLog.normalize(String($0)).uppercased() }.filter { !$0.isEmpty }
        return tokens.count > 1 && tokens.allSatisfy(words.contains)
    }
}

import SwiftUI

/// Settings: which words never count.
struct ReadFilterSettings: View {
    @State private var text = (UserDefaults.standard.stringArray(forKey: "readIgnoreWords") ?? ReadFilter.defaultWords).joined(separator: "\n")
    @State private var japaneseOnly = UserDefaults.standard.object(forKey: "readJapaneseOnly") as? Bool ?? true
    @State private var editing = false

    var body: some View {
        Toggle("Only count lines with Japanese in them", isOn: $japaneseOnly)
            .onChange(of: japaneseOnly) { _, v in UserDefaults.standard.set(v, forKey: "readJapaneseOnly") }
        HStack {
            Text("Words that never count: \(words.count) (セーブ, ロード, オート, SAVE …)")
            Spacer()
            Button(editing ? "Done" : "Edit…") { editing.toggle() }
        }
        if editing {
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 160)
                .onChange(of: text) { _, _ in
                    UserDefaults.standard.set(words, forKey: "readIgnoreWords")
                    UserDefaults.standard.set(true, forKey: "readIgnoreWordsEdited")
                }
            HStack {
                Text("One word or phrase per line. Matches whole lines only, so ログ won't remove sentences containing it.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Reset to Defaults") {
                    text = ReadFilter.defaultWords.joined(separator: "\n")
                    UserDefaults.standard.removeObject(forKey: "readIgnoreWords")
                    UserDefaults.standard.removeObject(forKey: "readIgnoreWordsEdited")
                }
            }
        }
    }

    private var words: [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
