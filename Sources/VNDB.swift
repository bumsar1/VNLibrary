import Foundation

/// What we keep from VNDB for a game.
struct VNInfo: Codable, Equatable {
    var id: String              // "v20424"
    var title: String
    var alttitle: String?
    var released: String?
    var lengthMinutes: Int?
    var rating: Double?         // 10–100
    var description: String?
    var developers: [String] = []
    var tags: [String] = []
    var eroTags: [String]?      // VNDB's sexual-content tags; optional for older files

    var url: URL { URL(string: "https://vndb.org/\(id)")! }
    var year: String? { released.map { String($0.prefix(4)) } }
}

/// Client for the public VNDB Kana API (no login needed for reading).
enum VNDB {
    struct Result: Decodable, Identifiable {
        struct Image: Decodable { let url: String; let sexual: Double? }
        struct Developer: Decodable { let name: String }
        struct Tag: Decodable { let name: String; let rating: Double; let spoiler: Int; let category: String? }

        let id: String
        let title: String
        let alttitle: String?
        let released: String?
        let length_minutes: Int?
        let rating: Double?
        let description: String?
        let image: Image?
        let developers: [Developer]
        let tags: [Tag]
        let votecount: Int?

        var info: VNInfo {
            // Spoiler tags are never kept. Sexual-content tags are stored apart
            // so the library can hide them.
            func top(_ categories: Set<String>, _ limit: Int) -> [String] {
                tags.filter { $0.spoiler == 0 && categories.contains($0.category ?? "") && $0.rating >= 1.5 }
                    .sorted { $0.rating > $1.rating }
                    .prefix(limit)
                    .map(\.name)
            }
            return VNInfo(id: id, title: title, alttitle: alttitle, released: released,
                          lengthMinutes: length_minutes, rating: rating,
                          description: description.map(VNDB.cleanDescription),
                          developers: developers.map(\.name), tags: top(["cont", "tech"], 20),
                          eroTags: top(["ero"], 15))
        }
        var year: String? { released.map { String($0.prefix(4)) } }
        /// Covers flagged as more than mildly suggestive are blurred in search results.
        var explicitCover: Bool { (image?.sexual ?? 0) >= 1 }
    }

    private struct Response: Decodable { let results: [Result]; let more: Bool? }

    enum BrowseSort: String, CaseIterable, Identifiable {
        case relevance, rating, votecount, released
        var id: String { rawValue }
        var label: String {
            switch self {
            case .relevance: return "Best match"
            case .rating: return "Highest rated"
            case .votecount: return "Most popular"
            case .released: return "Newest"
            }
        }
    }

    /// One page of VNDB for the Discover tab. With no query it lists the
    /// whole database in the chosen order (only VNs with enough votes when
    /// sorting by rating, so obscure 10/10s with two votes don't top it).
    static func browse(_ query: String, sort: BrowseSort, page: Int) async throws -> (results: [Result], more: Bool) {
        let q = query.trimmingCharacters(in: .whitespaces)
        var filters: [Any] = []
        if !q.isEmpty { filters.append(["search", "=", q]) }
        if sort == .rating { filters.append(["votecount", ">=", 100]) }
        if sort == .released { filters.append(["released", "<=", "today"]) }
        let filter: Any? = filters.isEmpty ? nil : filters.count == 1 ? filters[0] : ["and"] + filters
        let sortKey = sort == .relevance ? (q.isEmpty ? "votecount" : "searchrank") : sort.rawValue
        var payload: [String: Any] = ["fields": fields, "results": 40, "page": page,
                                      "sort": sortKey, "reverse": sortKey != "searchrank"]
        if let filter { payload["filters"] = filter }
        let response = try await post(payload)
        return (response.results, response.more ?? false)
    }

    private static let fields = [
        "id", "title", "alttitle", "released", "length_minutes", "rating", "description",
        "image.url", "image.sexual", "developers.name",
        "tags.name", "tags.rating", "tags.spoiler", "tags.category", "votecount",
    ].joined(separator: ",")

    static func search(_ query: String, results: Int = 10) async throws -> [Result] {
        try await request(["search", "=", query], results: results)
    }

    static func fetch(id: String) async throws -> Result? {
        try await request(["id", "=", id], results: 1).first
    }

    private static func request(_ filter: [String], results: Int) async throws -> [Result] {
        // searchrank is only valid together with a search filter.
        let sort = filter.first == "search" ? "searchrank" : "id"
        return try await post(["filters": filter, "fields": fields, "results": results, "sort": sort]).results
    }

    private static func post(_ payload: [String: Any]) async throws -> Response {
        var req = URLRequest(url: URL(string: "https://api.vndb.org/kana/vn")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "VNDB", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "VNDB returned \(http.statusCode): \(msg)"])
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    static func download(_ url: String) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: URL(string: url)!)
        return data
    }

    /// Turns a folder name into something VNDB's search will match:
    /// drops [group tags], (notes), version numbers and underscores.
    static func query(from name: String) -> String {
        var s = name.replacingOccurrences(of: "_", with: " ")
        for pattern in [#"\[[^\]]*\]"#, #"\([^)]*\)"#, #"\bv?\d+(\.\d+)+\b"#] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Whether an automatic match is close enough to trust: the titles must
    /// share most of their words, so a non-VN app doesn't get a random cover.
    static func plausible(_ r: Result, for query: String) -> Bool {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        }
        let q = words(query)
        guard !q.isEmpty else { return false }
        return [r.title, r.alttitle ?? ""].contains { title in
            let t = words(title)
            guard !t.isEmpty else { return false }
            let shared = q.intersection(t).count
            // The VNDB title sits inside the name ("Summer Pockets" in
            // "Summer Pockets REFLECTION BLUE"), or the two mostly overlap.
            // A name of two or more words inside a longer title also counts
            // ("Grisaia no Kajitsu" in "Grisaia no Kajitsu -LE FRUIT DE LA
            // GRISAIA-"); a single word ("Chess") is too weak on its own.
            return t.isSubset(of: q) || (q.count >= 2 && q.isSubset(of: t))
                || Double(shared) / Double(max(q.count, t.count)) >= 0.6
        }
    }

    /// VNDB descriptions use BBCode; keep the text and drop spoilers.
    static func cleanDescription(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"\[spoiler\][\s\S]*?\[/spoiler\]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[url=[^\]]*\]([\s\S]*?)\[/url\]"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[/?[a-z]+[^\]]*\]"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
