import Foundation
import Security

/// Two-way sync with the user's VNDB list: status labels, vote, notes and
/// dates go up when they change here, and can be imported from VNDB.
/// Needs an API token with the listread + listwrite permissions, created
/// under Profile → Applications on vndb.org.
enum VNDBAccount {
    struct AuthInfo: Decodable { let id: String; let username: String; let permissions: [String] }

    private static let base = "https://api.vndb.org/kana"

    // MARK: Token (kept in the keychain, not in preferences)

    private static let service = "dk.cadesign.vnlibrary.vndb"

    static var token: String? {
        get {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnData as String: true]
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
                  let data = out as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service]
            SecItemDelete(q as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var add = q
            add[kSecValueData as String] = Data(newValue.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    // MARK: Requests

    private static func request(_ method: String, _ path: String, token: String, body: [String: Any]? = nil) async throws -> Data {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = code == 401 ? "The token was rejected. Check that it's correct and not expired."
                : "VNDB returned \(code): \(String(data: data, encoding: .utf8) ?? "")"
            throw NSError(domain: "VNDB", code: code, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return data
    }

    static func authInfo(token: String) async throws -> AuthInfo {
        try JSONDecoder().decode(AuthInfo.self, from: try await request("GET", "/authinfo", token: token))
    }

    private static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Writes a game's status, vote, notes and dates to the user's VNDB list.
    static func push(_ game: Game, token: String) async throws {
        guard let vid = game.vndb?.id else { return }
        var body: [String: Any] = [
            "vote": game.userRating.map { $0 * 10 } ?? NSNull(),
            "notes": game.notes ?? "",
        ]
        // VNDB rejects null dates, so they're only sent once set.
        if let d = game.started { body["started"] = day(d) }
        if let d = game.finished { body["finished"] = day(d) }
        let all = PlayStatus.allCases.map(\.vndbLabel)
        if let status = game.status {
            body["labels_set"] = [status.vndbLabel]
            body["labels_unset"] = all.filter { $0 != status.vndbLabel }
        } else {
            body["labels_unset"] = all
        }
        _ = try await request("PATCH", "/ulist/\(vid)", token: token, body: body)
    }

    struct Entry: Decodable {
        struct Label: Decodable { let id: Int }
        let id: String
        let vote: Int?
        let notes: String?
        let started: String?
        let finished: String?
        let labels: [Label]?
    }
    private struct ListResponse: Decodable { let results: [Entry]; let more: Bool }

    /// The user's list entries for the given VNs.
    static func entries(for vids: [String], user: String, token: String) async throws -> [Entry] {
        var out: [Entry] = []
        for chunk in stride(from: 0, to: vids.count, by: 100).map({ Array(vids[$0..<min($0 + 100, vids.count)]) }) {
            let filter: [Any] = chunk.count == 1 ? ["id", "=", chunk[0]] : ["or"] + chunk.map { ["id", "=", $0] }
            let body: [String: Any] = ["user": user, "fields": "id, vote, notes, started, finished, labels.id",
                                       "filters": filter, "results": 100]
            let data = try await request("POST", "/ulist", token: token, body: body)
            out += try JSONDecoder().decode(ListResponse.self, from: data).results
        }
        return out
    }

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }
}

extension Library {
    var vndbSyncEnabled: Bool { vndbUser != nil && VNDBAccount.token != nil }

    /// Pushes a game's tracking to VNDB a moment after the last change, so
    /// typing notes doesn't send a request per keystroke.
    func scheduleVNDBSync(_ id: UUID) {
        guard vndbSyncEnabled else { return }
        syncTasks[id]?.cancel()
        syncTasks[id] = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let token = VNDBAccount.token,
                  let game = games.first(where: { $0.id == id }), game.vndb != nil else { return }
            do {
                try await VNDBAccount.push(game, token: token)
            } catch {
                alert = "Couldn't update your VNDB list: \(error.localizedDescription)"
            }
            syncTasks[id] = nil
        }
    }

    /// Saves and checks a token; returns the VNDB username.
    func connectVNDB(token: String) async throws -> String {
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = try await VNDBAccount.authInfo(token: clean)
        guard info.permissions.contains("listwrite"), info.permissions.contains("listread") else {
            throw NSError(domain: "VNDB", code: 0, userInfo: [NSLocalizedDescriptionKey:
                "The token needs both “Access to my list (including private items)” and “Write to my list”."])
        }
        VNDBAccount.token = clean
        vndbUser = info.id
        vndbUsername = info.username
        return info.username
    }

    func disconnectVNDB() {
        VNDBAccount.token = nil
        vndbUser = nil
        vndbUsername = nil
    }

    /// Takes status, vote, notes and dates from the VNDB list for every linked game.
    func importFromVNDB() async -> String {
        guard let token = VNDBAccount.token, let user = vndbUser else { return "Connect your VNDB account first." }
        let linked = games.compactMap { g in g.vndb.map { (g.id, $0.id) } }
        guard !linked.isEmpty else { return "No games are linked to VNDB yet." }
        do {
            let entries = try await VNDBAccount.entries(for: linked.map(\.1), user: user, token: token)
            let byVid = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var n = 0
            for (id, vid) in linked {
                guard let e = byVid[vid], let i = games.firstIndex(where: { $0.id == id }) else { continue }
                if let s = PlayStatus.from(vndbLabels: (e.labels ?? []).map(\.id)) { games[i].status = s }
                if let v = e.vote { games[i].userRating = Int((Double(v) / 10).rounded()) }
                if let notes = e.notes, !notes.isEmpty { games[i].notes = notes }
                if let d = VNDBAccount.date(e.started) { games[i].started = d }
                if let d = VNDBAccount.date(e.finished) { games[i].finished = d }
                n += 1
            }
            save()
            return n == 0 ? "None of your games are on your VNDB list yet."
                : "Imported \(n) game\(n == 1 ? "" : "s") from your VNDB list."
        } catch {
            return "Import failed: \(error.localizedDescription)"
        }
    }

    /// Pushes every linked game with tracking data to VNDB.
    func exportToVNDB() async -> String {
        guard let token = VNDBAccount.token else { return "Connect your VNDB account first." }
        let list = games.filter { $0.vndb != nil && ($0.status != nil || $0.userRating != nil || $0.notes != nil) }
        var failed = 0
        for g in list {
            do { try await VNDBAccount.push(g, token: token) } catch { failed += 1 }
        }
        return failed == 0 ? "Sent \(list.count) game\(list.count == 1 ? "" : "s") to your VNDB list."
            : "Sent \(list.count - failed), \(failed) failed."
    }
}
