import SwiftUI

/// Where a game stands for the user. Raw values double as VNDB list labels.
enum PlayStatus: String, Codable, CaseIterable, Identifiable {
    case playing, finished, onHold, dropped, planned
    var id: String { rawValue }
    var label: String {
        switch self {
        case .playing: return "Playing"
        case .finished: return "Finished"
        case .onHold: return "On hold"
        case .dropped: return "Dropped"
        case .planned: return "Plan to play"
        }
    }
    var symbol: String {
        switch self {
        case .playing: return "play.circle.fill"
        case .finished: return "checkmark.circle.fill"
        case .onHold: return "pause.circle.fill"
        case .dropped: return "xmark.circle.fill"
        case .planned: return "bookmark.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .playing: return Color.kAccent
        case .finished: return Color.kDone
        case .onHold: return Color.kFlame
        case .dropped: return Color.kHinomaru
        case .planned: return Color(hex: 0x60A5FA)
        }
    }
    /// VNDB's built-in list labels: Playing, Finished, Stalled, Dropped, Wishlist.
    var vndbLabel: Int {
        switch self {
        case .playing: return 1
        case .finished: return 2
        case .onHold: return 3
        case .dropped: return 4
        case .planned: return 5
        }
    }
    static func from(vndbLabels labels: [Int]) -> PlayStatus? {
        // A VN can carry several labels; the most "advanced" one wins.
        for s in [PlayStatus.finished, .playing, .onHold, .dropped, .planned] where labels.contains(s.vndbLabel) {
            return s
        }
        return nil
    }
}

extension Library {
    /// Games shown at all: discreet mode leaves out adult ones.
    var visibleGames: [Game] { discreet ? games.filter { !$0.isAdult } : games }

    var allCollections: [String] {
        Set(games.flatMap { $0.collections ?? [] }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func mutate(_ id: UUID, sync: Bool = true, _ change: (inout Game) -> Void) {
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        change(&games[i])
        save()
        if sync { scheduleVNDBSync(id) }
    }

    func setStatus(_ id: UUID, _ status: PlayStatus?) {
        mutate(id) { g in
            g.status = status
            let today = Date()
            if status == .playing, g.started == nil { g.started = today }
            if status == .finished {
                if g.started == nil { g.started = g.lastPlayed ?? today }
                g.finished = today
            }
        }
    }

    func setRating(_ id: UUID, _ rating: Int?) {
        mutate(id) { $0.userRating = rating }
    }

    func setNotes(_ id: UUID, _ notes: String) {
        mutate(id) { $0.notes = notes.isEmpty ? nil : notes }
    }

    func setAdult(_ id: UUID, _ adult: Bool) {
        mutate(id, sync: false) { $0.adult = adult }
    }

    func toggleCollection(_ id: UUID, _ name: String) {
        mutate(id, sync: false) { g in
            var c = g.collections ?? []
            if let i = c.firstIndex(of: name) { c.remove(at: i) } else { c.append(name) }
            g.collections = c.isEmpty ? nil : c
        }
    }

    /// Starting a game you haven't given a status counts as playing it.
    func markPlayingIfNew(_ id: UUID) {
        guard let g = games.first(where: { $0.id == id }), g.status == nil || g.status == .planned else { return }
        setStatus(id, .playing)
    }

    /// A random game to play next: something on the plan-to-play list, or
    /// failing that anything not finished or dropped.
    func randomPick() -> Game? {
        let pool = visibleGames
        let planned = pool.filter { $0.status == .planned }
        if let g = planned.randomElement() { return g }
        return pool.filter { $0.status != .finished && $0.status != .dropped }.randomElement()
    }
}

/// Status, rating, collections and the adult flag, shared by the card's
/// context menu and the game page.
struct TrackingMenus: View {
    @EnvironmentObject var lib: Library
    let game: Game
    let open: (SheetKind) -> Void

    var body: some View {
        Menu("Status") {
            ForEach(PlayStatus.allCases) { st in
                Toggle(st.label, isOn: Binding(get: { game.status == st },
                                               set: { lib.setStatus(game.id, $0 ? st : nil) }))
            }
        }
        Menu("My Rating") {
            ForEach((1...10).reversed(), id: \.self) { r in
                Toggle("\(r)  \(ratingWord(r))", isOn: Binding(get: { game.userRating == r },
                                                              set: { lib.setRating(game.id, $0 ? r : nil) }))
            }
            if game.userRating != nil {
                Divider()
                Button("Remove Rating") { lib.setRating(game.id, nil) }
            }
        }
        Menu("Collections") {
            ForEach(lib.allCollections, id: \.self) { c in
                Toggle(c, isOn: Binding(get: { game.collections?.contains(c) ?? false },
                                        set: { _ in lib.toggleCollection(game.id, c) }))
            }
            if !lib.allCollections.isEmpty { Divider() }
            Button("New Collection…") { open(.newCollection(game.id)) }
        }
        Toggle("Adult Game", isOn: Binding(get: { game.isAdult }, set: { lib.setAdult(game.id, $0) }))
    }
}

/// VNDB's words for its 1–10 vote scale.
func ratingWord(_ r: Int) -> String {
    ["", "Worst ever", "Awful", "Bad", "Weak", "Average", "Fine", "Good", "Very good", "Excellent", "Masterpiece"][max(0, min(10, r))]
}

struct StatusBadge: View {
    let status: PlayStatus
    var rating: Int?
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.symbol)
            Text(status.label)
            if let rating { Text("· \(rating)★") }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(status.color.opacity(0.9)))
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
    }
}

struct NewCollectionSheet: View {
    @EnvironmentObject var lib: Library
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Collection").font(.system(size: 16, weight: .bold))
            TextField("Name, e.g. Key games", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func create() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        lib.toggleCollection(id, n)
        dismiss()
    }
}
