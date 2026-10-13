import Foundation
import Security

/// Reading statistics from jiten.moe for a VN: length in characters,
/// difficulty, vocabulary and, with an API key, how much of it you know.
struct JitenInfo: Codable, Equatable {
    var deckId: Int
    var title: String
    var characters: Int
    var difficulty: Double          // jiten.moe's 0–5 scale
    var uniqueWords: Int
    var uniqueKanji: Int
    var averageSentence: Double
    var dialogue: Double            // percent
    var coverage: Double?           // percent of words known; needs an API key
    var fetched = Date()

    var url: URL { URL(string: "https://jiten.moe/decks/media/\(deckId)/detail")! }

    var difficultyLabel: String {
        switch difficulty {
        case ..<1: return "Very easy"
        case ..<2: return "Easy"
        case ..<3: return "Average"
        case ..<4: return "Hard"
        default: return "Very hard"
        }
    }
}

enum Jiten {
    private static let api = "https://api.jiten.moe/api"
    /// jiten.moe's link type for VNDB ids.
    private static let vndbLink = 2

    // MARK: API key (keychain)

    private static let service = "dk.cadesign.vnlibrary.jiten"

    static var key: String? {
        get {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecReturnData as String: true]
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
                  let data = out as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            SecItemDelete(q as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var add = q
            add[kSecValueData as String] = Data(newValue.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func get(_ path: String) async throws -> Any {
        var req = URLRequest(url: URL(string: api + path)!)
        req.timeoutInterval = 20
        if let key { req.setValue(key, forHTTPHeaderField: "X-Api-Key") }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return try JSONSerialization.jsonObject(with: data)
    }

    private struct Deck: Decodable {
        let deckId: Int
        let originalTitle: String?
        let romajiTitle: String?
        let englishTitle: String?
        let characterCount: Int?
        let difficultyRaw: Double?
        let difficulty: Double?
        let uniqueWordCount: Int?
        let uniqueKanjiCount: Int?
        let averageSentenceLength: Double?
        let dialoguePercentage: Double?
        let coverage: Double?
    }

    private static func deck(_ id: Int) async throws -> Deck? {
        var req = URLRequest(url: URL(string: "\(api)/media-deck/\(id)/detail")!)
        req.timeoutInterval = 20
        if let key { req.setValue(key, forHTTPHeaderField: "X-Api-Key") }
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let body = (obj["data"] as? [String: Any]) ?? obj
        let main = (body["mainDeck"] as? [String: Any]) ?? body
        return try JSONDecoder().decode(Deck.self, from: JSONSerialization.data(withJSONObject: main))
    }

    /// The jiten.moe deck for a VNDB id. A VN can have several (an original
    /// and a re-release); the one whose title best matches `name` wins.
    static func info(vndb vid: String, name: String) async -> JitenInfo? {
        guard let ids = try? await get("/media-deck/by-link-id/\(vndbLink)/\(vid)") as? [Int], !ids.isEmpty else { return nil }
        var decks: [Deck] = []
        for id in ids.prefix(6) { if let d = try? await deck(id) { decks.append(d) } }
        func score(_ d: Deck) -> Int {
            let wanted = Set(name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            return [d.originalTitle, d.romajiTitle, d.englishTitle].compactMap { $0 }.map { t in
                wanted.intersection(t.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)).count
            }.max() ?? 0
        }
        guard let best = decks.max(by: { (score($0), $0.characterCount ?? 0) < (score($1), $1.characterCount ?? 0) }) else { return nil }
        let cov = best.coverage ?? 0
        return JitenInfo(deckId: best.deckId,
                         title: best.originalTitle ?? best.romajiTitle ?? name,
                         characters: best.characterCount ?? 0,
                         difficulty: best.difficultyRaw ?? best.difficulty ?? 0,
                         uniqueWords: best.uniqueWordCount ?? 0,
                         uniqueKanji: best.uniqueKanjiCount ?? 0,
                         averageSentence: best.averageSentenceLength ?? 0,
                         dialogue: best.dialoguePercentage ?? 0,
                         coverage: key != nil && cov > 0 ? cov : nil)
    }
}

extension Library {
    /// Fetches jiten.moe stats for one game (quietly; many VNs aren't there).
    func fetchJiten(_ id: UUID) async {
        guard let g = games.first(where: { $0.id == id }), let vid = g.vndb?.id else { return }
        let info = await Jiten.info(vndb: vid, name: g.name)
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        games[i].jiten = info
        save()
    }

    func refreshJitenAll() {
        Task { for g in games where g.vndb != nil { await fetchJiten(g.id) } }
    }

    /// The name shown for a game: its original Japanese title when that
    /// setting is on and VNDB has one.
    func displayName(_ game: Game) -> String {
        if japaneseTitles, let alt = game.vndb?.alttitle, !alt.isEmpty { return alt }
        return game.name
    }
}

enum Count {
    /// 732095 → "732k", 1083609 → "1.08M".
    static func short(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
        if n >= 10_000 { return "\(n / 1000)k" }
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }
}

import SwiftUI

/// One line of jiten.moe stats; click to open the deck on jiten.moe.
struct JitenLine: View {
    let info: JitenInfo
    var body: some View {
        var parts = ["\(Count.short(info.characters)) characters",
                     String(format: "difficulty %.1f/5 (%@)", info.difficulty, info.difficultyLabel),
                     "\(Count.short(info.uniqueWords)) unique words",
                     "\(Count.short(info.uniqueKanji)) kanji"]
        if let c = info.coverage { parts.append(String(format: "you know %.0f%%", c)) }
        return Button { NSWorkspace.shared.open(info.url) } label: {
            HStack(spacing: 6) {
                Text("jiten.moe").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.kAccent)
                Text(parts.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(Color.kMuted)
                    .lineLimit(2)
            }
        }
        .buttonStyle(.plain)
        .help("Open on jiten.moe")
    }
}

/// Optional jiten.moe API key, for "you know N%" coverage.
struct JitenKeyRow: View {
    @EnvironmentObject var lib: Library
    @State private var key = ""
    @State private var saved = Jiten.key != nil

    var body: some View {
        if saved {
            HStack {
                Label("jiten.moe key saved (shows how many words you know)", systemImage: "checkmark.circle")
                    .foregroundStyle(Color.kDone).font(.system(size: 12))
                Spacer()
                Button("Remove") { Jiten.key = nil; saved = false; lib.refreshJitenAll() }
            }
        } else {
            HStack {
                SecureField("jiten.moe API key (optional)", text: $key)
                Button("Save") {
                    Jiten.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    key = ""
                    saved = true
                    lib.refreshJitenAll()
                }
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Difficulty and length work without a key. With one (jiten.moe → Settings → API), you also see how much of each VN's vocabulary you know.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
