import GameController
import SwiftUI

/// Full-screen browsing from the sofa, like a console: rows for your games
/// and for VNDB categories, an on-screen keyboard for search, a screenshot
/// backdrop and UI sounds. Arrow keys or a game controller; Return / A acts,
/// Esc / B goes back, Y or / searches.
struct CouchView: View {
    @EnvironmentObject var lib: Library
    let close: () -> Void

    enum Item: Identifiable {
        case game(Game)
        case remote(VNDB.Result)
        var id: String {
            switch self {
            case .game(let g): return g.id.uuidString
            case .remote(let r): return r.id
            }
        }
        var vid: String? {
            switch self {
            case .game(let g): return g.vndb?.id
            case .remote(let r): return r.id
            }
        }
    }

    struct Row: Identifiable {
        let id: String
        let title: String
        let items: [Item]
    }

    /// A VNDB category row: extra filter conditions and an order.
    struct Category {
        let id: String
        let title: String
        let conditions: [Any]
        let sort: String
        let reverse: Bool
    }

    enum Input { case left, right, up, down, accept, back, search, start, backspace, type(String) }

    @State private var row = 0
    @State private var cols: [String: Int] = [:]
    @State private var categories: [Category] = []
    @State private var remote: [String: [VNDB.Result]] = [:]
    @State private var adultRemote: Set<String> = []
    @State private var backdrops: [String: String] = [:]    // VNDB id → screenshot URL
    @State private var toast: String?
    @State private var keyMonitor: Any?
    @State private var lastStick = Date.distantPast
    @State private var keyboard = CouchKeyboard()
    @State private var typing = false
    @State private var query = ""                            // the committed search
    @State private var searchResults: [VNDB.Result] = []
    @State private var detail: Item?                         // the game page that's open
    @State private var detailState = CouchDetailState()
    @State private var rows: [Row] = []                      // rebuilt only when their inputs change
    @State private var galleries: [String: [GalleryImage]] = [:]
    @State private var connectObserver: NSObjectProtocol?

    // MARK: Rows

    /// Recomputing rows on every render was the main cost while moving around;
    /// they're rebuilt here when the library, search or VNDB rows change.
    private func rebuildRows() {
        rows = buildRows()
        if row >= rows.count { row = max(0, rows.count - 1) }
    }

    private func buildRows() -> [Row] {
        let games = lib.sorted(.recent, filter: "")
        let installed = games.filter { lib.exists($0) }
        let playing = installed.filter { $0.status == .playing }.map(Item.game)
        let ready = installed.filter { $0.status != .playing }.map(Item.game)
        let notReady = games.filter { !lib.exists($0) }.map(Item.game)
        let owned = Set(lib.games.compactMap { $0.vndb?.id })

        var out: [Row] = []
        if !query.isEmpty {
            let mine = lib.sorted(.name, filter: query).map(Item.game)
            out.append(Row(id: "s-lib", title: "Your library · “\(query)”", items: mine))
            out.append(Row(id: "s-vndb", title: "VNDB · “\(query)”", items: searchResults.filter(allowed).map(Item.remote)))
        }
        out += [Row(id: "playing", title: "Continue playing", items: playing),
                Row(id: "ready", title: "Ready to play", items: ready),
                Row(id: "not", title: "Not installed", items: notReady)]
        for c in categories {
            let items = (remote[c.id] ?? []).filter { !owned.contains($0.id) && allowed($0) }.map(Item.remote)
            out.append(Row(id: c.id, title: c.title, items: items))
        }
        return out.filter { !$0.items.isEmpty }
    }

    /// Discreet mode leaves adult VNs out of the VNDB rows.
    private func allowed(_ r: VNDB.Result) -> Bool {
        !(lib.discreet && (adultRemote.contains(r.id) || r.hasSexualTags))
    }

    /// What the backdrop and header follow: the open game page, else the focused tile.
    private var shown: Item? { detail ?? current }

    private var current: Item? {
        let r = rows
        guard r.indices.contains(row) else { return nil }
        let items = r[row].items
        let c = min(cols[r[row].id] ?? 0, items.count - 1)
        return c >= 0 ? items[c] : nil
    }

    // MARK: Body

    var body: some View {
        content
            .onAppear(perform: rebuildRows)
            .onChange(of: lib.games) { _, _ in rebuildRows() }
            .onChange(of: lib.discreet) { _, _ in rebuildRows() }
            .onChange(of: query) { _, _ in rebuildRows() }
            .onChange(of: searchResults.map(\.id)) { _, _ in rebuildRows() }
            .onChange(of: remote.mapValues { $0.count }) { _, _ in rebuildRows() }
            .onChange(of: adultRemote) { _, _ in if lib.discreet { rebuildRows() } }
    }

    private var content: some View {
        let list = rows
        return ZStack {
            backdrop
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.2), .black.opacity(0.9)],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .leading, endPoint: .center)
            if detail != nil { Color.black.opacity(0.4).transition(.opacity) }   // keeps the page readable

            if let detail {
                CouchDetailView(item: detail, state: detailState)
                    .transition(.opacity)
                Text(detailHint)
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.horizontal, 48).padding(.top, 36)
            } else {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    Text("VN Library").font(.system(size: 20, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                    Button { handle(.search) } label: {
                        Label(query.isEmpty ? "Search" : "“\(query)”", systemImage: "magnifyingglass")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Text("↑↓←→ move    ⏎ / Ⓐ \(actionHint)    / or Ⓨ search    esc / Ⓑ \(query.isEmpty ? "back" : "clear search")")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                }
                if let current { details(current).frame(height: 190, alignment: .bottomLeading) }
                Spacer(minLength: 0)
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { ri, r in
                                rowView(r, focused: ri == row).id(r.id)
                            }
                        }
                    }
                    .frame(maxHeight: 480)
                    .onChange(of: row) { _, i in
                        if list.indices.contains(i) { withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(list[i].id, anchor: .top) } }
                    }
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 36)
            }

            if list.isEmpty && detail == nil {
                Text("No games to show.").font(.title2).foregroundStyle(.white.opacity(0.7))
            }
            if typing {
                Color.black.opacity(0.5).onTapGesture { handle(.back) }
                CouchKeyboardView(keyboard: keyboard) { r, c in
                    keyboard.row = r
                    keyboard.col = c
                    handle(.accept)
                }
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
            if let toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.75)))
                        .padding(.bottom, 30)
                }
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .onAppear(perform: start)
        .onDisappear(perform: stop)
        .task {
            // Test hooks: open the keyboard with some text, or run a search.
            let env = ProcessInfo.processInfo.environment
            if let t = env["VNLIB_COUCH_TYPE"] { keyboard.text = t; keyboard.mode = .hiragana; typing = true }
            if let q = env["VNLIB_COUCH_QUERY"] { keyboard.text = q; commitSearch() }
            await loadCategories()
            if let r = env["VNLIB_COUCH_ROW"].flatMap(Int.init) { row = r }
            if env["VNLIB_COUCH_OPEN"] != nil { act() }
        }
        .task(id: shown?.id) { await loadBackdrop() }
    }

    private var actionHint: String { current == nil ? "select" : "open" }

    private var detailHint: String {
        if detailState.viewing != nil { return "" }
        let onRating = detail.map { Self.buttons(for: $0, lib: lib) }.map { b in
            detailState.focusRow == 0 && b.indices.contains(detailState.col) && b[detailState.col] == .rating } ?? false
        return onRating ? "Ⓐ / ⏎ +1    Ⓧ / − −1    ↓ images    Ⓑ / esc back"
                        : "← → choose    Ⓐ / ⏎ select    ↓ images    Ⓑ / esc back"
    }

    // MARK: Background

    /// A VNDB screenshot of the focused game, sharp and full-bleed; the cover
    /// (softly blurred) until one arrives or when there's none.
    private var backdrop: some View {
        Color.black
            .overlay {
                if let vid = shown?.vid, let url = backdrops[vid], !url.isEmpty, !lib.discreet {
                    AsyncImage(url: URL(string: url)) { phase in
                        if let img = phase.image {
                            img.resizable().scaledToFill()
                        } else {
                            coverBackdrop
                        }
                    }
                    .id(url)
                    .transition(.opacity)
                } else {
                    coverBackdrop
                }
            }
            .clipped()
            .animation(.easeInOut(duration: 0.4), value: shown?.id)
    }

    @ViewBuilder
    private var coverBackdrop: some View {
        switch shown {
        case .game(let g):
            if let img = lib.discreet || g.isBlurred ? lib.blurredImage(for: g) : lib.image(for: g) {
                Image(nsImage: img).resizable().scaledToFill().blur(radius: 18).opacity(0.7)
            }
        case .remote(let r):
            if let u = r.image?.url {
                RemoteImage(url: u, blurred: true).opacity(0.6)
            }
        case nil:
            EmptyView()
        }
    }

    private func loadBackdrop() async {
        guard let vid = shown?.vid, backdrops[vid] == nil else { return }
        try? await Task.sleep(for: .milliseconds(250))     // don't fetch while scrolling past
        guard !Task.isCancelled, shown?.vid == vid else { return }
        let images = await gallery(vid)
        let limit = lib.blurSuggestive ? 0.5 : 1.5
        // "" remembers "no usable screenshot" so it isn't fetched again.
        backdrops[vid] = images.first(where: { $0.kind == "Screenshot" && $0.sexual < limit })?.url ?? ""
    }

    /// VNDB images for a VN, fetched once per couch session (backdrop and game page share them).
    private func gallery(_ vid: String) async -> [GalleryImage] {
        if let g = galleries[vid] { return g }
        let g = (try? await VNDB.gallery(for: vid)) ?? []
        galleries[vid] = g
        return g
    }

    // MARK: Row views

    private func rowView(_ r: Row, focused: Bool) -> some View {
        let col = min(cols[r.id] ?? 0, r.items.count - 1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(r.title.uppercased())
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(focused ? 0.95 : 0.55))
                Text("\(r.items.count)").font(.system(size: 13)).foregroundStyle(.white.opacity(0.45))
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .bottom, spacing: 18) {
                        ForEach(Array(r.items.enumerated()), id: \.element.id) { i, item in
                            tileView(item, row: r, index: i, selected: focused && i == col, focused: focused)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                    .animation(.spring(response: 0.28, dampingFraction: 0.82), value: col)
                    .animation(.spring(response: 0.28, dampingFraction: 0.82), value: focused)
                }
                .onChange(of: col) { _, c in
                    if r.items.indices.contains(c) { withAnimation { proxy.scrollTo(r.items[c].id, anchor: .center) } }
                }
            }
        }
    }

    private func tileView(_ item: Item, row r: Row, index i: Int, selected: Bool, focused: Bool) -> some View {
        let adult = isAdult(item)
        return tile(item)
            .frame(width: selected ? 200 : (focused ? 160 : 120),
                   height: selected ? 267 : (focused ? 213 : 160))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? Color.white : (adult ? Color.kHinomaru : Color.clear), lineWidth: selected ? 3 : 2))
            .overlay(alignment: .bottomTrailing) { if adult { AdultBadge().padding(6) } }
            .overlay(alignment: .topLeading) { badge(item).padding(6) }
            .shadow(color: .black.opacity(0.6), radius: selected ? 20 : 6, y: 8)
            .opacity(focused ? (selected ? 1 : 0.75) : 0.5)
            .id(item.id)
            .onTapGesture {
                if let ri = rows.firstIndex(where: { $0.id == r.id }) { row = ri }
                if selected { act() } else { cols[r.id] = i; CouchSounds.shared.play(.move) }
            }
    }

    @ViewBuilder
    private func tile(_ item: Item) -> some View {
        switch item {
        case .game(let g): CoverView(game: g)
        case .remote(let r): RemoteCover(result: r)
        }
    }

    @ViewBuilder
    private func badge(_ item: Item) -> some View {
        if case .game(let g) = item, let st = g.status { StatusBadge(status: st, rating: g.userRating) }
    }

    private func isAdult(_ item: Item) -> Bool {
        switch item {
        case .game(let g): return g.isAdult
        case .remote(let r): return adultRemote.contains(r.id) || r.hasSexualTags
        }
    }

    @ViewBuilder
    private func details(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Spacer(minLength: 0)
            switch item {
            case .game(let g):
                Text(lib.displayName(g)).font(.system(size: 40, weight: .bold)).foregroundStyle(.white).lineLimit(2)
                HStack(spacing: 14) {
                    if let dev = g.vndb?.developers.first { Text(dev) }
                    if let y = g.vndb?.year { Text(y) }
                    if g.playSeconds > 0 { Text("Played \(Format.playtime(g.playSeconds))") }
                    if let r = lib.routeProgress(g) { Text(r) }
                    if let j = g.jiten { Text(String(format: "difficulty %.1f", j.difficulty)) }
                    if lib.running[g.id] != nil { Text("Running").foregroundStyle(Color.kDone) }
                    if !lib.exists(g) { Text("Not installed").foregroundStyle(Color.kFlame) }
                }
                .font(.system(size: 16)).foregroundStyle(.white.opacity(0.8))
                if let d = g.vndb?.description { blurb(d) }
            case .remote(let r):
                Text(lib.japaneseTitles ? (r.alttitle ?? r.title) : r.title)
                    .font(.system(size: 40, weight: .bold)).foregroundStyle(.white).lineLimit(2)
                HStack(spacing: 14) {
                    if let dev = r.developers.first?.name { Text(dev) }
                    if let rel = r.released { Text(rel) }
                    if let rt = r.rating { Text("★ " + String(format: "%.1f", rt / 10)) }
                    if let m = r.length_minutes, m > 0 { Text("~\(max(1, m / 60)) h") }
                    Text("On VNDB").foregroundStyle(Color(hex: 0x60A5FA))
                }
                .font(.system(size: 16)).foregroundStyle(.white.opacity(0.8))
                if let d = r.info.description { blurb(d) }
            }
        }
        .shadow(color: .black.opacity(0.8), radius: 8)
    }

    private func blurb(_ text: String) -> some View {
        Text(text).font(.system(size: 15)).foregroundStyle(.white.opacity(0.75)).lineLimit(3)
            .frame(maxWidth: 900, alignment: .leading)
    }

    // MARK: Loading

    /// The VNDB rows, all on top of the user's Discover language filters.
    private func loadCategories() async {
        guard categories.isEmpty else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        let today = f.string(from: Date())
        var cats = [
            Category(id: "new", title: "New releases", conditions: [["released", "<=", today]], sort: "released", reverse: true),
            Category(id: "upcoming", title: "Coming soon", conditions: [["released", ">", today]], sort: "released", reverse: false),
            Category(id: "top", title: "Highest rated", conditions: [["votecount", ">=", 100]], sort: "rating", reverse: true),
            Category(id: "popular", title: "Most popular", conditions: [], sort: "votecount", reverse: true),
            Category(id: "gems", title: "Hidden gems",
                     conditions: [["rating", ">=", 78], ["votecount", ">=", 20], ["votecount", "<=", 250]], sort: "rating", reverse: true),
        ]
        if let tag = await favouriteTag() {
            cats.append(Category(id: "rec", title: "Because you like \(tag.name)",
                                 conditions: [["tag", "=", tag.id], ["votecount", ">=", 30]], sort: "rating", reverse: true))
        }
        if let extra = await easiestCategory() { cats.insert(extra, at: 1) }
        categories = cats
        let base = DiscoverFilters.load()
        // Reopening couch mode within half an hour reuses the rows already fetched.
        let key = String(describing: base.conditions)
        if let cached = CouchCache.shared.rows(for: key) {
            remote = cached.rows
            adultRemote = cached.adult
            return
        }
        // All rows at once; each appears as soon as its request is back.
        await withTaskGroup(of: (String, [VNDB.Result], Set<String>).self) { group in
            for c in cats {
                group.addTask {
                    let results = c.id == "easy" ? await Jiten.easiestVNs() :
                        await VNDB.row(c.conditions, sort: c.sort, reverse: c.reverse, base: base)
                    return (c.id, results, await VNDB.adultIDs(results.map(\.id)))
                }
            }
            for await (id, results, adult) in group {
                remote[id] = results
                adultRemote.formUnion(adult)
            }
        }
        CouchCache.shared.store(remote, adult: adultRemote, for: key)
    }

    /// "Easiest for you" from jiten.moe: by your known vocabulary with an API
    /// key, otherwise by jiten's difficulty.
    private func easiestCategory() async -> Category? {
        Category(id: "easy", title: Jiten.key != nil ? "Easiest for you (jiten.moe)" : "Easiest to read (jiten.moe)",
                 conditions: [], sort: "", reverse: false)
    }

    /// The most common tag among the games you liked or are into, leaving
    /// out tags almost every VN has.
    private func favouriteTag() async -> DiscoverFilters.TagRef? {
        let generic: Set<String> = ["Male Protagonist", "ADV", "Multiple Endings", "Romance", "Slice of Life", "Protagonist with a Face",
                                    "Protagonist with Voice Acting", "Comedy", "Drama", "High School", "Sprite Viewer", "Music Recollection",
                                    "Normal Scene Recollection", "Achievements", "Insert Songs", "Branching Plot", "Few Choices",
                                    "Only Virgin Heroines", "Heroine with Big Breasts", "Twitter", "Long Common Route"]
        var counts: [String: Int] = [:]
        for g in lib.games where (g.userRating ?? 0) >= 8 || g.status == .finished || g.status == .playing {
            // Tags come most relevant first; weigh them that way, and count
            // games you rated highly double.
            let weight = (g.userRating ?? 0) >= 8 ? 2 : 1
            for (i, t) in (g.vndb?.tags ?? []).enumerated() where !generic.contains(t) {
                counts[t, default: 0] += max(1, 20 - i) * weight
            }
        }
        guard let name = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        return await VNDB.searchTags(name).first { $0.0.name == name }?.0
    }

    private func runSearch() async {
        let q = query
        searchResults = (try? await VNDB.browse(q, sort: .relevance, page: 1, filters: {
            var f = DiscoverFilters(); f.languages = []; return f
        }()).results) ?? []
        adultRemote.formUnion(await VNDB.adultIDs(searchResults.map(\.id)))
    }

    // MARK: Actions

    private func handle(_ input: Input) {
        if typing { return handleKeyboard(input) }
        if detail != nil { return handleDetail(input) }
        switch input {
        case .left: move(col: -1)
        case .right: move(col: 1)
        case .up: move(row: -1)
        case .down: move(row: 1)
        case .accept: act()
        case .back:
            if !query.isEmpty {
                query = ""
                searchResults = []
                row = 0
                CouchSounds.shared.play(.back)
            } else {
                CouchSounds.shared.play(.back)
                close()
            }
        case .search, .start:
            keyboard.text = query
            withAnimation(.easeOut(duration: 0.15)) { typing = true }
            CouchSounds.shared.play(.select)
        case .type(let s):
            // Typing straight away opens search with that letter.
            keyboard.text = query + s
            withAnimation(.easeOut(duration: 0.15)) { typing = true }
        case .backspace: break
        }
    }

    private func handleKeyboard(_ input: Input) {
        func moved(_ ok: Bool) { CouchSounds.shared.play(ok ? .move : .error) }
        switch input {
        case .left: moved(keyboard.move(dx: -1, dy: 0))
        case .right: moved(keyboard.move(dx: 1, dy: 0))
        case .up: moved(keyboard.move(dx: 0, dy: -1))
        case .down: moved(keyboard.move(dx: 0, dy: 1))
        case .accept:
            CouchSounds.shared.play(.row)
            if keyboard.press() { commitSearch() }
        case .back:
            if keyboard.text.isEmpty {
                withAnimation { typing = false }
                CouchSounds.shared.play(.back)
            } else {
                _ = keyboard.press(.backspace)
                CouchSounds.shared.play(.move)
            }
        case .backspace:
            _ = keyboard.press(.backspace)
        case .search:
            _ = keyboard.press(.mode)
            CouchSounds.shared.play(.row)
        case .start:
            commitSearch()
        case .type(let s):
            keyboard.text += s
        }
    }

    private func commitSearch() {
        let q = keyboard.text.trimmingCharacters(in: .whitespaces)
        withAnimation { typing = false }
        query = q
        row = 0
        searchResults = []
        guard !q.isEmpty else { return }
        CouchSounds.shared.play(.select)
        Task { await runSearch() }
    }

    private func move(col step: Int) {
        let r = rows
        guard r.indices.contains(row) else { return }
        let n = r[row].items.count
        let c = min(cols[r[row].id] ?? 0, n - 1) + step
        guard c >= 0, c < n else { CouchSounds.shared.play(.error); return }
        cols[r[row].id] = c
        CouchSounds.shared.play(.move)
    }

    private func move(row step: Int) {
        let next = row + step
        guard rows.indices.contains(next) else { CouchSounds.shared.play(.error); return }
        row = next
        CouchSounds.shared.play(.row)
    }

    /// Opens the game page for the focused tile.
    private func act() {
        guard let item = current else { CouchSounds.shared.play(.error); return }
        CouchSounds.shared.play(.select)
        detailState = CouchDetailState()
        withAnimation(.easeInOut(duration: 0.2)) { detail = item }
        if let vid = item.vid {
            Task {
                let images = await gallery(vid)
                if detail?.id == item.id { detailState.images = images }
            }
        }
    }

    private func closeDetail() {
        CouchSounds.shared.play(.back)
        withAnimation(.easeInOut(duration: 0.2)) { detail = nil }
    }

    private func handleDetail(_ input: Input) {
        guard let item = detail else { return }
        let buttons = Self.buttons(for: item, lib: lib)
        let images = detailState.images
        func step(_ d: Int, count: Int) {
            let c = detailState.col + d
            guard c >= 0, c < count else { CouchSounds.shared.play(.error); return }
            detailState.col = c
            CouchSounds.shared.play(.move)
        }
        // A gallery image is open full screen.
        if let i = detailState.viewing {
            switch input {
            case .left, .right:
                let back: Bool = { if case .left = input { return true } else { return false } }()
                let n = (i + (back ? -1 : 1) + images.count) % max(images.count, 1)
                detailState.viewing = n
                detailState.col = n
                CouchSounds.shared.play(.move)
            case .accept:
                let img = images[i]
                if lib.shouldBlur(sexual: img.sexual, key: img.url) && !lib.discreet {
                    lib.revealed.insert(img.url)
                    CouchSounds.shared.play(.row)
                } else {
                    detailState.viewing = nil
                    CouchSounds.shared.play(.back)
                }
            case .back, .backspace:
                detailState.viewing = nil
                CouchSounds.shared.play(.back)
            default: break
            }
            return
        }
        switch input {
        case .left: step(-1, count: detailState.focusRow == 0 ? buttons.count : images.count)
        case .right: step(1, count: detailState.focusRow == 0 ? buttons.count : images.count)
        case .down:
            guard detailState.focusRow == 0, !images.isEmpty else { CouchSounds.shared.play(.error); return }
            detailState.focusRow = 1
            detailState.col = 0
            CouchSounds.shared.play(.row)
        case .up:
            guard detailState.focusRow == 1, !buttons.isEmpty else { CouchSounds.shared.play(.error); return }
            detailState.focusRow = 0
            detailState.col = 0
            CouchSounds.shared.play(.row)
        case .accept:
            if detailState.focusRow == 1 {
                guard images.indices.contains(detailState.col) else { return }
                detailState.viewing = detailState.col
                CouchSounds.shared.play(.select)
            } else if buttons.indices.contains(detailState.col) {
                press(buttons[detailState.col], item: item, delta: 1)
            }
        case .backspace:
            // X lowers the rating when it's focused.
            if detailState.focusRow == 0, buttons.indices.contains(detailState.col), buttons[detailState.col] == .rating {
                press(.rating, item: item, delta: -1)
            }
        case .type(let t):
            if t == "-" { handleDetail(.backspace) } else if t == "+" || t == "=" { handleDetail(.accept) }
        case .back: closeDetail()
        case .search, .start: break
        }
    }

    private func press(_ button: CouchDetailState.Button, item: Item, delta: Int) {
        let gameID: UUID? = {
            switch item {
            case .game(let g): return g.id
            case .remote(let r): return lib.games.first { $0.vndb?.id == r.id }?.id
            }
        }()
        let game = gameID.flatMap { id in lib.games.first { $0.id == id } }
        switch button {
        case .play:
            guard let game else { return }
            CouchSounds.shared.play(.select)
            lib.launch(game, fullScreen: true)
            show("Starting \(lib.displayName(game))…")
        case .status:
            guard let game else { return }
            // Cycles: none → Playing → Finished → On hold → Dropped → Plan to play → none.
            let order: [PlayStatus?] = [nil, .playing, .finished, .onHold, .dropped, .planned]
            let i = order.firstIndex(of: game.status) ?? 0
            lib.setStatus(game.id, order[(i + 1) % order.count])
            CouchSounds.shared.play(.row)
        case .rating:
            guard let game else { return }
            let r = game.userRating ?? (delta > 0 ? 6 : 1)
            let next = r + (game.userRating == nil ? 0 : delta)
            lib.setRating(game.id, next < 1 || next > 10 ? nil : next)
            CouchSounds.shared.play(next < 1 || next > 10 ? .back : .row)
        case .add:
            guard case .remote(let r) = item else { return }
            CouchSounds.shared.play(.add)
            Task {
                await lib.addFromVNDB(r)
                detailState.col = 0
                show("Added \(r.title) to Plan to play")
            }
        }
    }

    private func show(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation { if toast == text { toast = nil } }
        }
    }

    // MARK: Input

    private func start() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            switch e.keyCode {
            case 123: handle(.left)
            case 124: handle(.right)
            case 126: handle(.up)
            case 125: handle(.down)
            case 36, 76: handle(typing ? .start : .accept)        // return, enter
            case 53: handle(.back)                                // esc
            case 51: handle(typing ? .backspace : .back)          // delete
            case 48: handle(.search)                              // tab
            default:
                guard let chars = e.charactersIgnoringModifiers, !chars.isEmpty,
                      !e.modifierFlags.contains(.command) else { return e }
                if chars == "/" && !typing { handle(.search) }
                else if chars == " " && !typing { handle(.accept) }
                else if chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                    handle(.type(e.characters ?? chars))
                } else { return e }
            }
            return nil
        }
        // Kept so it can be removed: re-entering couch mode used to stack observers.
        connectObserver = NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { note in
            if let c = note.object as? GCController { MainActor.assumeIsolated { attach(c) } }
        }
        GCController.controllers().forEach(attach)
        GCController.startWirelessControllerDiscovery {}
    }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        pad.dpad.left.pressedChangedHandler = { _, _, p in if p { handle(.left) } }
        pad.dpad.right.pressedChangedHandler = { _, _, p in if p { handle(.right) } }
        pad.dpad.up.pressedChangedHandler = { _, _, p in if p { handle(.up) } }
        pad.dpad.down.pressedChangedHandler = { _, _, p in if p { handle(.down) } }
        pad.buttonA.pressedChangedHandler = { _, _, p in if p { handle(.accept) } }
        pad.buttonB.pressedChangedHandler = { _, _, p in if p { handle(.back) } }
        pad.buttonY.pressedChangedHandler = { _, _, p in if p { handle(.search) } }
        pad.buttonX.pressedChangedHandler = { _, _, p in if p { handle(.backspace) } }
        pad.buttonMenu.pressedChangedHandler = { _, _, p in if p { handle(.start) } }
        pad.leftThumbstick.valueChangedHandler = { _, x, y in
            // The stick works like the d-pad, at most a step every 0.22 s.
            guard max(abs(x), abs(y)) > 0.6, Date().timeIntervalSince(lastStick) > 0.22 else { return }
            lastStick = Date()
            if abs(x) > abs(y) { handle(x > 0 ? .right : .left) } else { handle(y > 0 ? .up : .down) }
        }
    }

    private func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let connectObserver { NotificationCenter.default.removeObserver(connectObserver) }
        connectObserver = nil
        GCController.stopWirelessControllerDiscovery()
        for c in GCController.controllers() {
            guard let pad = c.extendedGamepad else { continue }
            for b in [pad.dpad.left, pad.dpad.right, pad.dpad.up, pad.dpad.down,
                      pad.buttonA, pad.buttonB, pad.buttonX, pad.buttonY, pad.buttonMenu] {
                b.pressedChangedHandler = nil
            }
            pad.leftThumbstick.valueChangedHandler = nil
        }
    }
}

/// VNDB rows kept between couch-mode sessions for a while.
@MainActor
final class CouchCache {
    static let shared = CouchCache()
    private var entry: (key: String, at: Date, rows: [String: [VNDB.Result]], adult: Set<String>)?

    func rows(for key: String) -> (rows: [String: [VNDB.Result]], adult: Set<String>)? {
        guard let e = entry, e.key == key, Date().timeIntervalSince(e.at) < 30 * 60 else { return nil }
        return (e.rows, e.adult)
    }

    func store(_ rows: [String: [VNDB.Result]], adult: Set<String>, for key: String) {
        entry = (key, Date(), rows, adult)
    }
}
