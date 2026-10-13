import GameController
import SwiftUI

/// Full-screen browsing from the sofa, like a console: rows for what's ready
/// to play, what isn't installed, and new releases from Discover. Arrow keys
/// or a game controller move around; Return / A acts, Esc / B leaves.
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

    @State private var row = 0
    @State private var cols: [String: Int] = [:]
    @State private var discover: [VNDB.Result] = []
    @State private var adultRemote: Set<String> = []
    @State private var backdrops: [String: String] = [:]    // VNDB id → screenshot URL
    @State private var toast: String?
    @State private var keyMonitor: Any?
    @State private var lastStick = Date.distantPast

    private var rows: [Row] {
        let games = lib.sorted(.recent, filter: "")
        let ready = games.filter { lib.exists($0) }.map(Item.game)
        let notReady = games.filter { !lib.exists($0) }.map(Item.game)
        let owned = Set(lib.games.compactMap { $0.vndb?.id })
        let fresh = discover.filter { r in
            !owned.contains(r.id) && !(lib.discreet && (adultRemote.contains(r.id) || !(r.info.eroTags ?? []).isEmpty))
        }.map(Item.remote)
        return [Row(id: "ready", title: "Ready to play", items: ready),
                Row(id: "not", title: "Not installed", items: notReady),
                Row(id: "discover", title: "Discover · new releases", items: fresh)]
            .filter { !$0.items.isEmpty }
    }

    private var current: Item? {
        let r = rows
        guard r.indices.contains(row) else { return nil }
        let items = r[row].items
        let c = min(cols[r[row].id] ?? 0, items.count - 1)
        return c >= 0 ? items[c] : nil
    }

    var body: some View {
        let list = rows
        ZStack {
            backdrop
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.2), .black.opacity(0.9)],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .leading, endPoint: .center)

            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("VN Library").font(.system(size: 20, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Text("↑ ↓  row     ← →  choose     ⏎ / Ⓐ  \(actionHint)     esc / Ⓑ  back")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                }
                if let current { details(current).frame(height: 190, alignment: .bottomLeading) }
                Spacer(minLength: 0)
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { ri, r in
                                rowView(r, focused: ri == row).id(r.id)
                            }
                        }
                    }
                    .frame(maxHeight: 470)
                    .onChange(of: row) { _, i in
                        if list.indices.contains(i) { withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(list[i].id, anchor: .top) } }
                    }
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 36)

            if list.isEmpty {
                Text("No games to show.").font(.title2).foregroundStyle(.white.opacity(0.7))
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
        .task { await loadDiscover() }
        .task(id: current?.id) { await loadBackdrop() }
    }

    private var actionHint: String {
        switch current {
        case .game(let g): return lib.exists(g) ? "play" : "info"
        case .remote: return "add to plan to play"
        case nil: return "select"
        }
    }

    // MARK: Background

    /// A VNDB screenshot of the focused game, sharp and full-bleed; the cover
    /// (softly blurred) until one arrives or when there's none.
    private var backdrop: some View {
        Color.black
            .overlay {
                if let vid = current?.vid, let url = backdrops[vid], !lib.discreet {
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
            .animation(.easeInOut(duration: 0.4), value: current?.id)
    }

    @ViewBuilder
    private var coverBackdrop: some View {
        switch current {
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
        guard let vid = current?.vid, backdrops[vid] == nil else { return }
        try? await Task.sleep(for: .milliseconds(250))     // don't fetch while scrolling past
        guard !Task.isCancelled, current?.vid == vid else { return }
        let images = (try? await VNDB.gallery(for: vid)) ?? []
        let limit = lib.blurSuggestive ? 0.5 : 1.5
        if let shot = images.first(where: { $0.kind == "Screenshot" && $0.sexual < limit }) {
            backdrops[vid] = shot.url
        }
    }

    // MARK: Rows

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
                    HStack(alignment: .bottom, spacing: 18) {
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
        case .remote(let r): return adultRemote.contains(r.id) || !(r.info.eroTags ?? []).isEmpty
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

    // MARK: Actions

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

    private func act() {
        switch current {
        case .game(let g):
            if lib.exists(g) {
                CouchSounds.shared.play(.select)
                lib.launch(g)
                show("Starting \(lib.displayName(g))…")
            } else {
                CouchSounds.shared.play(.error)
                show(g.installed ? "Its folder is missing. Fix the path under Edit." : "Not installed yet. Drop its game folder into the library.")
            }
        case .remote(let r):
            CouchSounds.shared.play(.add)
            Task {
                await lib.addFromVNDB(r)
                show("Added \(r.title) to Plan to play")
            }
        case nil:
            CouchSounds.shared.play(.error)
        }
    }

    private func show(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation { if toast == text { toast = nil } }
        }
    }

    private func leave() {
        CouchSounds.shared.play(.back)
        close()
    }

    private func loadDiscover() async {
        guard discover.isEmpty,
              let r = try? await VNDB.browse("", sort: .released, page: 1, filters: DiscoverFilters.load()) else { return }
        discover = r.results
        adultRemote = await VNDB.adultIDs(r.results.map(\.id))
    }

    // MARK: Input

    private func start() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            switch e.keyCode {
            case 123: move(col: -1); return nil          // ←
            case 124: move(col: 1); return nil           // →
            case 126: move(row: -1); return nil          // ↑
            case 125: move(row: 1); return nil           // ↓
            case 36, 76, 49: act(); return nil           // return, enter, space
            case 53: leave(); return nil                 // esc
            default: return e
            }
        }
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { note in
            if let c = note.object as? GCController { MainActor.assumeIsolated { attach(c) } }
        }
        GCController.controllers().forEach(attach)
        GCController.startWirelessControllerDiscovery {}
    }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        pad.dpad.left.pressedChangedHandler = { _, _, p in if p { move(col: -1) } }
        pad.dpad.right.pressedChangedHandler = { _, _, p in if p { move(col: 1) } }
        pad.dpad.up.pressedChangedHandler = { _, _, p in if p { move(row: -1) } }
        pad.dpad.down.pressedChangedHandler = { _, _, p in if p { move(row: 1) } }
        pad.buttonA.pressedChangedHandler = { _, _, p in if p { act() } }
        pad.buttonB.pressedChangedHandler = { _, _, p in if p { leave() } }
        pad.leftThumbstick.valueChangedHandler = { _, x, y in
            // The stick works like the d-pad, at most a step every 0.22 s.
            guard max(abs(x), abs(y)) > 0.6, Date().timeIntervalSince(lastStick) > 0.22 else { return }
            lastStick = Date()
            if abs(x) > abs(y) { move(col: x > 0 ? 1 : -1) } else { move(row: y > 0 ? -1 : 1) }
        }
    }

    private func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        GCController.stopWirelessControllerDiscovery()
        for c in GCController.controllers() {
            guard let pad = c.extendedGamepad else { continue }
            for b in [pad.dpad.left, pad.dpad.right, pad.dpad.up, pad.dpad.down, pad.buttonA, pad.buttonB] {
                b.pressedChangedHandler = nil
            }
            pad.leftThumbstick.valueChangedHandler = nil
        }
    }
}
