import SwiftUI

/// A route to clear, usually a heroine from VNDB, or one the user added.
struct Route: Codable, Identifiable, Equatable {
    var id: String                  // VNDB character id, or "custom-<uuid>"
    var name: String
    var original: String?
    var image: String?
    var sexual: Double = 0
}

extension VNDB {
    private struct CharResponse: Decodable {
        struct C: Decodable {
            struct Img: Decodable { let url: String; let sexual: Double? }
            struct VNRole: Decodable { let id: String; let role: String; let spoiler: Int }
            let id: String
            let name: String
            let original: String?
            let image: Img?
            let vns: [VNRole]
        }
        let results: [C]
        let more: Bool
    }

    /// The VN's heroines: characters VNDB lists as "primary", without spoilers.
    static func heroines(for vid: String) async throws -> [Route] {
        var out: [Route] = []
        var page = 1
        while page <= 3 {
            var req = URLRequest(url: URL(string: "https://api.vndb.org/kana/character")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "filters": ["vn", "=", ["id", "=", vid]],
                "fields": "id,name,original,image.url,image.sexual,vns.id,vns.role,vns.spoiler",
                "results": 100, "page": page,
            ])
            let r = try JSONDecoder().decode(CharResponse.self, from: try await URLSession.shared.data(for: req).0)
            for c in r.results {
                guard let role = c.vns.first(where: { $0.id == vid }), role.role == "primary", role.spoiler == 0,
                      !out.contains(where: { $0.name == c.name }) else { continue }
                out.append(Route(id: c.id, name: c.name, original: c.original, image: c.image?.url, sexual: c.image?.sexual ?? 0))
            }
            if !r.more { break }
            page += 1
        }
        return out
    }
}

extension Library {
    func fetchRoutes(_ id: UUID, replace: Bool = false) async {
        guard let g = games.first(where: { $0.id == id }), let vid = g.vndb?.id,
              replace || g.routes == nil,
              let list = try? await VNDB.heroines(for: vid),
              let i = games.firstIndex(where: { $0.id == id }) else { return }
        // Keep routes the user added by hand.
        games[i].routes = list + (games[i].routes ?? []).filter { $0.id.hasPrefix("custom-") }
        save()
    }

    func toggleRoute(_ id: UUID, _ route: String) {
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        var done = games[i].routesDone ?? []
        if let k = done.firstIndex(of: route) { done.remove(at: k) } else { done.append(route) }
        games[i].routesDone = done
        save()
    }

    func addRoute(_ id: UUID, name: String) {
        guard let i = games.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        games[i].routes = (games[i].routes ?? []) + [Route(id: "custom-\(UUID().uuidString)", name: name)]
        save()
    }

    func removeRoute(_ id: UUID, _ route: String) {
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        games[i].routes?.removeAll { $0.id == route }
        games[i].routesDone?.removeAll { $0 == route }
        save()
    }

    /// "2/4 routes", or nil when the game has no route list.
    func routeProgress(_ g: Game) -> String? {
        guard let r = g.routes, !r.isEmpty else { return nil }
        let done = r.filter { g.routesDone?.contains($0.id) ?? false }.count
        return "\(done)/\(r.count) routes"
    }
}

/// Heroine portraits with a check for each cleared route.
struct RoutesSection: View {
    @EnvironmentObject var lib: Library
    let game: Game
    @State private var adding = false
    @State private var newName = ""

    var body: some View {
        let routes = game.routes ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(lib.routeProgress(game).map { "ROUTES · \($0.uppercased())" } ?? "ROUTES")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.kMuted)
                Spacer()
                Menu {
                    Button("Add Route…") { adding = true }
                    if game.vndb != nil {
                        Button("Reload Heroines from VNDB") { Task { await lib.fetchRoutes(game.id, replace: true) } }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if routes.isEmpty {
                Text(game.vndb == nil ? "Link the game to VNDB to load its heroines, or add routes yourself."
                                      : "No heroines listed on VNDB. Add routes yourself with ⋯.")
                    .font(.system(size: 12)).foregroundStyle(Color.kMuted)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(routes) { r in card(r) }
                    }
                }
            }
            if adding {
                HStack {
                    TextField("Route name, e.g. True ending", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Add", action: add)
                    Button("Cancel") { adding = false; newName = "" }
                }
            }
        }
    }

    private func add() {
        lib.addRoute(game.id, name: newName.trimmingCharacters(in: .whitespaces))
        newName = ""
        adding = false
    }

    private func card(_ r: Route) -> some View {
        let done = game.routesDone?.contains(r.id) ?? false
        return VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let img = r.image {
                        RemoteImage(url: img, blurred: lib.shouldBlur(sexual: r.sexual, key: img))
                    } else {
                        ZStack {
                            Color.kPanel2
                            Text(String(r.name.prefix(1))).font(.system(size: 26, weight: .bold)).foregroundStyle(Color.kMuted)
                        }
                    }
                }
                .frame(width: 70, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .saturation(done ? 1 : 0.35)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(done ? Color.kDone : Color.kLine, lineWidth: done ? 2 : 1))
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white, Color.kDone)
                        .padding(3)
                }
            }
            Text(lib.japaneseTitles ? (r.original ?? r.name) : r.name)
                .font(.system(size: 10))
                .foregroundStyle(done ? Color.kText : Color.kMuted)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 74)
        }
        .contentShape(Rectangle())
        .onTapGesture { lib.toggleRoute(game.id, r.id) }
        .help(done ? "Cleared — click to unmark" : "Click when you've cleared this route")
        .contextMenu {
            Button(done ? "Mark as Not Cleared" : "Mark as Cleared") { lib.toggleRoute(game.id, r.id) }
            Button("Remove from Routes") { lib.removeRoute(game.id, r.id) }
        }
    }
}
