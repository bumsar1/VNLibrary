import SwiftUI

/// Search and browse all of VNDB, and add VNs to the library as "Plan to play".
struct DiscoverView: View {
    @EnvironmentObject var lib: Library
    let open: (SheetKind) -> Void

    @State private var query = ""
    @AppStorage("discoverSort") private var sort: VNDB.BrowseSort = .released
    @State private var filters = DiscoverFilters.load()
    @State private var showFilters = false
    @State private var adult: Set<String> = []
    @State private var results: [VNDB.Result] = []
    @State private var page = 1
    @State private var more = false
    @State private var loading = false
    @State private var error: String?
    @State private var searchedFor = ""

    var body: some View {
        VStack(spacing: 0) {
            controls
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 20, alignment: .top)], spacing: 22) {
                    ForEach(visible) { r in
                        DiscoverCard(result: r, adult: isAdult(r)).onTapGesture { open(.discover(r)) }
                    }
                }
                .padding(.horizontal, 24)
                if loading {
                    ProgressView().padding(30)
                } else if let error {
                    Text(error).foregroundStyle(Color.kHinomaru).font(.system(size: 12)).padding(30)
                } else if visible.isEmpty {
                    Text("Nothing found on VNDB.").foregroundStyle(Color.kMuted).padding(40)
                } else if more {
                    Button("Load More") { Task { await load(reset: false) } }
                        .padding(24)
                }
            }
        }
        .task {
            if ProcessInfo.processInfo.environment["VNLIB_OPEN_FILTERS"] != nil { showFilters = true }
            if results.isEmpty { await load(reset: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showDeveloper)) { _ in
            filters = DiscoverFilters.load()
        }
        .onChange(of: filters) { _, f in
            f.save()
            Task { await load(reset: true) }
        }
    }

    /// 18+ on VNDB (a release rated 18+), or carrying sexual-content tags.
    private func isAdult(_ r: VNDB.Result) -> Bool {
        adult.contains(r.id) || !(r.info.eroTags ?? []).isEmpty
    }

    /// Discreet mode leaves out adult VNs; optionally hide what's already owned.
    private var visible: [VNDB.Result] {
        results.filter { r in
            !(lib.discreet && isAdult(r))
                && !(filters.hideInLibrary && lib.games.contains { $0.vndb?.id == r.id })
        }
    }

    private var filterChips: some View {
        let chips = filters.chips
        return Group {
            if !chips.isEmpty {
                WrapLayout(spacing: 6) {
                    ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                        FilterChip(text: chip.label, symbol: "line.3.horizontal.decrease") { chip.clear(&filters) }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.kMuted)
                TextField("Search VNDB — English, romaji or Japanese title", text: $query)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Color.kText)
                    .onSubmit { Task { await load(reset: true) } }
                if !query.isEmpty {
                    Button { query = ""; Task { await load(reset: true) } } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Color.kMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.kPanel2))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.kLine))

            Picker("", selection: $sort) {
                ForEach(VNDB.BrowseSort.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)
            .onChange(of: sort) { _, _ in Task { await load(reset: true) } }

            Button { showFilters.toggle() } label: {
                Label(filters.chips.isEmpty ? "Filters" : "Filters (\(filters.chips.count))",
                      systemImage: "line.3.horizontal.decrease.circle")
            }
            .popover(isPresented: $showFilters, arrowEdge: .bottom) {
                DiscoverFilterPanel(filters: $filters)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        filterChips
    }

    private func load(reset: Bool) async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        let nextPage = reset ? 1 : page + 1
        do {
            let r = try await VNDB.browse(query, sort: sort, page: nextPage, filters: filters)
            let ids = r.results.map(\.id)
            Task { adult.formUnion(await VNDB.adultIDs(ids)) }
            results = reset ? r.results : results + r.results.filter { n in !results.contains { $0.id == n.id } }
            page = nextPage
            more = r.more
            searchedFor = query
        } catch {
            if reset { results = [] }
            self.error = "Couldn't reach VNDB: \(error.localizedDescription)"
        }
    }
}

/// Cover art straight from VNDB, blurred when VNDB flags it or in discreet mode.
struct RemoteCover: View {
    @EnvironmentObject var lib: Library
    let result: VNDB.Result
    /// Shows a "Show" button on a blurred cover (on the detail page).
    var revealable = false

    var body: some View {
        GeometryReader { geo in
            AsyncImage(url: result.image.flatMap { URL(string: $0.url) }) { phase in
                if let img = phase.image {
                    img.resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: hidden ? 22 : 0, opaque: true)
                } else {
                    ZStack {
                        LinearGradient(colors: [Color(hex: 0x3B2370), Color(hex: 0x1D1D21)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        if result.image == nil {
                            Text(result.title).font(.system(size: 14, weight: .bold))
                                .multilineTextAlignment(.center).foregroundStyle(Color.kText).padding(12)
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .overlay {
                if hidden {
                    VStack(spacing: 10) {
                        Image(systemName: "eye.slash").font(.system(size: 22))
                        if revealable && !lib.discreet {
                            Button("Show") { lib.revealed.insert(key) }
                                .buttonStyle(.borderedProminent)
                                .tint(Color.black.opacity(0.5))
                        }
                    }
                    .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
    }

    private var key: String { result.image?.url ?? result.id }
    private var hidden: Bool { lib.shouldBlur(sexual: result.image?.sexual ?? 0, key: key) }
}

struct DiscoverCard: View {
    @EnvironmentObject var lib: Library
    let result: VNDB.Result
    var adult = false
    @State private var hover = false

    var body: some View {
        let owned = lib.games.first { $0.vndb?.id == result.id }
        VStack(alignment: .leading, spacing: 7) {
            RemoteCover(result: result)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    if let owned {
                        Group {
                            if let st = owned.status {
                                StatusBadge(status: st, rating: owned.userRating)
                            } else {
                                Label("In library", systemImage: "checkmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Capsule().fill(Color.black.opacity(0.65)))
                            }
                        }
                        .padding(7)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(adult ? Color.kHinomaru : hover ? Color.kAccent : Color.kLine, lineWidth: adult ? 2.5 : 1))
                .overlay(alignment: .bottomTrailing) { if adult { AdultBadge().padding(7) } }
                .scaleEffect(hover ? 1.02 : 1)
                .animation(.easeOut(duration: 0.15), value: hover)
            Text(lib.japaneseTitles ? (result.alttitle ?? result.title) : result.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.kText)
                .lineLimit(2, reservesSpace: true)
            Text([result.year, result.rating.map { "★ " + String(format: "%.1f", $0 / 10) }]
                    .compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11))
                .foregroundStyle(Color.kMuted)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

/// A VN from VNDB that may not be in the library yet.
struct DiscoverSheet: View {
    @EnvironmentObject var lib: Library
    @Environment(\.dismiss) private var dismiss
    let result: VNDB.Result
    let open: (SheetKind) -> Void
    @State private var adding = false
    @State private var gallery: [GalleryImage] = []
    @State private var viewing: Int?
    @State private var jiten: JitenInfo?
    @State private var adult = false

    var body: some View {
        let info = result.info
        let owned = lib.games.first { $0.vndb?.id == result.id }
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                RemoteCover(result: result, revealable: true)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .frame(width: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(adult ? Color.kHinomaru : Color.kLine, lineWidth: adult ? 3 : 1))
                    .overlay(alignment: .bottomTrailing) { if adult { AdultBadge().padding(9) } }
                if !lib.discreet, lib.revealed.contains(result.image?.url ?? result.id) {
                    Button("Blur Again") { lib.revealed.remove(result.image?.url ?? result.id) }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.kText)
                        .textSelection(.enabled)
                    if let alt = result.alttitle {
                        Text(alt).font(.system(size: 14)).foregroundStyle(Color.kMuted).textSelection(.enabled)
                    }
                }
                if !info.developers.isEmpty {
                    DeveloperLinks(names: info.developers, ids: info.developerIDs) { dismiss() }
                }
                FlowChips(items: facts(info))
                if let jiten { JitenLine(info: jiten) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        GalleryStrip(vid: result.id, viewing: $viewing, images: $gallery)
                        Text(info.description ?? "No description on VNDB.")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.kText.opacity(0.9))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        let ero = lib.showEroTags && !lib.discreet ? info.eroTags ?? [] : []
                        if !(info.tags + ero).isEmpty {
                            Text("TAGS").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.kMuted)
                            WrapLayout(spacing: 5) {
                                ForEach(info.tags + ero, id: \.self) { t in
                                    TagButton(tag: t, ero: ero.contains(t)) {}
                                        .allowsHitTesting(false)
                                }
                            }
                        }
                    }
                    .padding(.trailing, 8)
                }
                .frame(maxHeight: .infinity)

                HStack {
                    if let owned {
                        Button {
                            open(.info(owned.id))
                        } label: {
                            Label("In Library — Open", systemImage: "checkmark")
                        }
                        .buttonStyle(AccentButtonStyle())
                    } else {
                        Button {
                            adding = true
                            Task {
                                let id = await lib.addFromVNDB(result)
                                adding = false
                                open(.info(id))
                            }
                        } label: {
                            Label(adding ? "Adding…" : "Add to Plan to Play", systemImage: "bookmark.fill")
                        }
                        .buttonStyle(AccentButtonStyle())
                        .disabled(adding)
                        .keyboardShortcut(.defaultAction)
                    }
                    Button("Open on vndb.org") { NSWorkspace.shared.open(info.url) }
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(24)
        .frame(width: 820, height: 580)
        .background(Color.kPanel)
        .overlay { GalleryViewer(images: gallery, index: $viewing, gameID: owned?.id) }
        .task {
            let rated18 = await VNDB.adultIDs([result.id])
            adult = !(result.info.eroTags ?? []).isEmpty || !rated18.isEmpty
            jiten = await Jiten.info(vndb: result.id, name: result.title)
        }
    }

    private func facts(_ info: VNInfo) -> [String] {
        var out: [String] = []
        if let y = info.year, y != "TBA" { out.append(y) }
        if let m = info.lengthMinutes, m > 0 { out.append("~\(max(1, Int((Double(m) / 60).rounded()))) hours") }
        if let r = info.rating { out.append("★ " + String(format: "%.2f", r / 10)) }
        if let v = result.votecount { out.append("\(v.formatted()) votes") }
        return out
    }
}

/// Small red "18+" tag for adult VNs.
struct AdultBadge: View {
    var body: some View {
        Text("18+")
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.kHinomaru))
            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
    }
}
