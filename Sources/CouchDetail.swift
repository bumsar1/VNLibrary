import SwiftUI

/// Couch mode's game page: everything about one VN, with controller-driven
/// buttons (play, status, rating, add) and a screenshot gallery.
struct CouchDetailState {
    enum Button: Hashable { case play, status, rating, add }
    var focusRow = 0            // 0 = buttons, 1 = gallery
    var col = 0
    var images: [GalleryImage] = []
    var viewing: Int?           // gallery image shown full screen
}

extension CouchView {
    static func buttons(for item: Item, lib: Library) -> [CouchDetailState.Button] {
        switch item {
        case .game(let g): return lib.exists(g) ? [.play, .status, .rating] : [.status, .rating]
        case .remote(let r): return lib.games.contains { $0.vndb?.id == r.id } ? [] : [.add]
        }
    }
}

struct CouchDetailView: View {
    @EnvironmentObject var lib: Library
    let item: CouchView.Item
    let state: CouchDetailState

    /// The library entry, live (status and rating change while the page is open).
    private var game: Game? {
        switch item {
        case .game(let g): return lib.games.first { $0.id == g.id } ?? g
        case .remote(let r): return lib.games.first { $0.vndb?.id == r.id }
        }
    }

    private var remote: VNDB.Result? { if case .remote(let r) = item { return r } else { return nil } }

    var body: some View {
        let buttons = CouchView.buttons(for: item, lib: lib)
        ZStack {
            VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 40) {
                cover
                    .frame(width: 300, height: 400)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(adult ? Color.kHinomaru : Color.white.opacity(0.2),
                                                                             lineWidth: adult ? 3 : 1))
                    .overlay(alignment: .bottomTrailing) { if adult { AdultBadge().padding(10) } }
                    .shadow(color: .black.opacity(0.6), radius: 24, y: 12)

                VStack(alignment: .leading, spacing: 14) {
                    Text(title).font(.system(size: 42, weight: .bold)).foregroundStyle(.white).lineLimit(2)
                    if let sub = subtitle {
                        Text(sub).font(.system(size: 18)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                    HStack(spacing: 10) {
                        ForEach(facts, id: \.self) { f in
                            Text(f).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(Color.white.opacity(0.12)))
                        }
                    }
                    if let j = game?.jiten {
                        Text(String(format: "jiten.moe · %@ characters · difficulty %.1f/5 (%@) · %@ unique words",
                                    Count.short(j.characters), j.difficulty, j.difficultyLabel, Count.short(j.uniqueWords)))
                            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                    }
                    if let g = game, !lib.lastLines(g.id).isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("WHERE YOU LEFT OFF").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                            ForEach(Array(lib.lastLines(g.id).enumerated()), id: \.offset) { _, l in
                                Text(l).font(.system(size: 15)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                            }
                        }
                    }
                    Text(description)
                        .font(.system(size: 16)).foregroundStyle(.white.opacity(0.85)).lineSpacing(3)
                        .lineLimit(5)
                        .frame(maxWidth: 820, alignment: .leading)
                    if !tags.isEmpty {
                        Text(tags.prefix(10).joined(separator: " · "))
                            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
                    }
                    HStack(spacing: 14) {
                        ForEach(Array(buttons.enumerated()), id: \.offset) { i, b in
                            buttonView(b, focused: state.focusRow == 0 && state.col == i)
                        }
                        if buttons.isEmpty {
                            Label("In your library", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.kDone)
                        }
                    }
                    if let g = game, !lib.exists(g) {
                        Text(g.installed ? "The game's folder is missing — fix it under Edit in the library."
                                         : "Not installed. Drop its game folder into the library to play it.")
                            .font(.system(size: 13)).foregroundStyle(Color.kFlame)
                    }
                }
            }
            .padding(.top, 70)
            Spacer(minLength: 0)
            gallery
            }

            if let i = state.viewing, state.images.indices.contains(i) {
                viewer(state.images[i], index: i)
            }
        }
        .padding(.horizontal, 60)
        .padding(.bottom, 36)
    }

    // MARK: Content

    private var adult: Bool {
        if let g = game { return g.isAdult }
        return (remote?.hasSexualTags ?? false)
    }

    private var title: String {
        if let g = game { return lib.displayName(g) }
        guard let r = remote else { return "" }
        return lib.japaneseTitles ? (r.alttitle ?? r.title) : r.title
    }

    private var subtitle: String? {
        if let g = game { return lib.displayName(g) != g.name ? g.name : g.vndb?.alttitle }
        guard let r = remote else { return nil }
        return lib.japaneseTitles ? r.title : r.alttitle
    }

    private var info: VNInfo? { game?.vndb ?? remote?.info }

    private var facts: [String] {
        var out: [String] = []
        if let d = info?.developers.first { out.append(d) }
        if let y = info?.year, y != "TBA" { out.append(y) }
        if let m = info?.lengthMinutes, m > 0 { out.append("~\(max(1, Int((Double(m) / 60).rounded()))) h") }
        if let r = info?.rating { out.append("★ " + String(format: "%.2f", r / 10)) }
        if let g = game {
            if g.playSeconds > 0 { out.append("Played \(Format.playtime(g.playSeconds))") }
            if let r = lib.routeProgress(g) { out.append(r) }
            if let c = g.readChars, c > 0 { out.append("\(Count.short(c)) chars read") }
        }
        return out
    }

    private var description: String { info?.description ?? "No description on VNDB." }

    private var tags: [String] {
        if let g = game { return lib.tags(of: g) }
        guard let i = remote?.info else { return [] }
        return i.tags + (lib.showEroTags && !lib.discreet ? i.eroTags ?? [] : [])
    }

    @ViewBuilder
    private var cover: some View {
        if let g = game { CoverView(game: g) } else if let r = remote { RemoteCover(result: r) }
    }

    // MARK: Buttons

    private func buttonView(_ b: CouchDetailState.Button, focused: Bool) -> some View {
        let (label, symbol): (String, String) = {
            switch b {
            case .play: return ("Play", "play.fill")
            case .status: return (game?.status.map { "Status: \($0.label)" } ?? "Set status", game?.status?.symbol ?? "bookmark")
            case .rating: return (game?.userRating.map { "My rating: \($0)" } ?? "Rate it", "star.fill")
            case .add: return ("Add to Plan to Play", "bookmark.fill")
            }
        }()
        return Label(label, systemImage: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(focused ? .black : .white)
            .padding(.horizontal, 22).padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 12).fill(focused ? Color.white : Color.white.opacity(b == .play || b == .add ? 0.22 : 0.1)))
            .scaleEffect(focused ? 1.06 : 1)
            .animation(.easeOut(duration: 0.12), value: focused)
    }

    // MARK: Gallery

    private var gallery: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !state.images.isEmpty {
                Text("IMAGES").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(state.focusRow == 1 ? 0.95 : 0.5))
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(Array(state.images.enumerated()), id: \.element.id) { i, img in
                                let focused = state.focusRow == 1 && state.col == i
                                RemoteImage(url: img.thumbnail, blurred: lib.shouldBlur(sexual: img.sexual, key: img.url))
                                    .frame(width: img.kind == "Screenshot" ? 200 : 90, height: 120)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Color.white : Color.clear, lineWidth: 3))
                                    .scaleEffect(focused ? 1.08 : 1)
                                    .opacity(state.focusRow == 1 ? 1 : 0.6)
                                    .id(i)
                            }
                        }
                        .padding(8)
                        .animation(.easeOut(duration: 0.15), value: state.col)
                    }
                    .onChange(of: state.col) { _, c in
                        if state.focusRow == 1 { withAnimation { proxy.scrollTo(c, anchor: .center) } }
                    }
                }
            }
        }
    }

    private func viewer(_ img: GalleryImage, index: Int) -> some View {
        ZStack {
            Color.black.opacity(0.96)
            RemoteImage(url: img.url, blurred: lib.shouldBlur(sexual: img.sexual, key: img.url), fit: true)
                .padding(40)
            VStack {
                Spacer()
                Text("\(img.kind) · \(index + 1) of \(state.images.count)    ← →  browse    Ⓐ  \(lib.shouldBlur(sexual: img.sexual, key: img.url) && !lib.discreet ? "show" : "close")    Ⓑ  close")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, 16)
            }
        }
        .padding(.horizontal, -60)
        .padding(.bottom, -36)
    }
}
