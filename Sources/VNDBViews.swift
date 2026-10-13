import AppKit
import SwiftUI

/// A game's page: cover, VNDB details and the play button.
struct InfoSheet: View {
    @EnvironmentObject var lib: Library
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    let open: (SheetKind) -> Void
    let filterTag: (String) -> Void
    @State private var notes = ""
    @State private var gallery: [GalleryImage] = []
    @State private var viewing: Int?

    var body: some View {
        if let game = lib.games.first(where: { $0.id == id }) {
            content(game)
        } else {
            Color.clear.frame(width: 1, height: 1).onAppear { dismiss() }
        }
    }

    private func content(_ game: Game) -> some View {
        let info = game.vndb
        return HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                CoverView(game: game)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .frame(width: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.kLine))
                trackingControls(game)
            }
            .frame(width: 240)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(game.name)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.kText)
                        .textSelection(.enabled)
                    if let alt = info?.alttitle, !alt.isEmpty {
                        Text(alt).font(.system(size: 14)).foregroundStyle(Color.kMuted).textSelection(.enabled)
                    } else if let t = info?.title, t != game.name {
                        Text(t).font(.system(size: 14)).foregroundStyle(Color.kMuted)
                    }
                }

                FlowChips(items: facts(game))

                // Description, tags and notes share one scroll area so a long
                // tag list never pushes the rest off the page.
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let vid = info?.id {
                            GalleryStrip(vid: vid, viewing: $viewing, images: $gallery)
                        }
                        if let info {
                            Text(info.description ?? "No description on VNDB.")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.kText.opacity(0.9))
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if !lib.tags(of: game).isEmpty {
                                Text("TAGS")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.kMuted)
                                WrapLayout(spacing: 5) {
                                    ForEach(lib.tags(of: game), id: \.self) { tag in
                                        TagButton(tag: tag, ero: lib.isEroTag(tag, of: game)) {
                                            filterTag(tag)
                                            dismiss()
                                        }
                                    }
                                }
                                .help("Click a tag to show every game that has it")
                            }
                        } else {
                            Text(lib.fetching.contains(id) ? "Fetching from VNDB…" : "No VNDB data yet.")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.kMuted)
                            if !lib.fetching.contains(id) {
                                Button("Find on VNDB…") { open(.vndb(id)) }
                            }
                        }
                        Text("MY NOTES")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.kMuted)
                        TextEditor(text: $notes)
                            .font(.system(size: 13))
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .frame(minHeight: 80)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.kPanel2))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.kLine))
                            .onChange(of: notes) { _, new in
                                if new != (game.notes ?? "") { lib.setNotes(id, new) }
                            }
                    }
                    .padding(.trailing, 8)
                }
                .frame(maxHeight: .infinity)

                HStack {
                    Button {
                        lib.launch(game)
                        dismiss()
                    } label: {
                        Label(lib.running[id] != nil ? "Running" : "Play", systemImage: "play.fill")
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(lib.running[id] != nil)
                    .keyboardShortcut(.defaultAction)

                    Menu("More") {
                        Button("Fetch from VNDB…") { open(.vndb(id)) }
                        if let info { Button("Open on vndb.org") { NSWorkspace.shared.open(info.url) } }
                        Button("Edit…") { open(.edit(game)) }
                        Button(game.isBlurred ? "Show Cover" : "Blur Cover") { lib.toggleBlur(id) }
                        Menu("Collections") {
                            ForEach(lib.allCollections, id: \.self) { c in
                                Toggle(c, isOn: Binding(get: { game.collections?.contains(c) ?? false },
                                                        set: { _ in lib.toggleCollection(id, c) }))
                            }
                            if !lib.allCollections.isEmpty { Divider() }
                            Button("New Collection…") { open(.newCollection(id)) }
                        }
                        Toggle("Adult Game", isOn: Binding(get: { game.isAdult }, set: { lib.setAdult(id, $0) }))
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: game.path)])
                        }
                        if info != nil {
                            Divider()
                            Button("Remove VNDB Data") { lib.forgetVNDB(id) }
                        }
                    }
                    .fixedSize()
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(24)
        .frame(width: 780, height: 540)
        .background(Color.kPanel)
        .onAppear { notes = game.notes ?? "" }
        .overlay { GalleryViewer(images: gallery, index: $viewing, gameID: id) }
        .onChange(of: gallery) { _, g in
            if ProcessInfo.processInfo.environment["VNLIB_VIEW_IMAGE"] != nil, !g.isEmpty { viewing = 0 }
        }
    }

    private func trackingControls(_ game: Game) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Status", selection: Binding(get: { game.status }, set: { lib.setStatus(id, $0) })) {
                Text("No status").tag(PlayStatus?.none)
                Divider()
                ForEach(PlayStatus.allCases) { st in
                    Label(st.label, systemImage: st.symbol).tag(PlayStatus?.some(st))
                }
            }
            Picker("Rating", selection: Binding(get: { game.userRating }, set: { lib.setRating(id, $0) })) {
                Text("Not rated").tag(Int?.none)
                Divider()
                ForEach((1...10).reversed(), id: \.self) { r in
                    Text("\(r) – \(ratingWord(r))").tag(Int?.some(r))
                }
            }
            if let c = game.collections, !c.isEmpty {
                Label(c.joined(separator: ", "), systemImage: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.kMuted)
                    .lineLimit(2)
            }
            if let s = game.started {
                Text(game.finished.map { "Played \(Format.date(s)) – \(Format.date($0))" } ?? "Started \(Format.date(s))")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.kMuted)
            }
        }
        .font(.system(size: 12))
    }

    private func facts(_ game: Game) -> [String] {
        var out: [String] = []
        if let info = game.vndb {
            if !info.developers.isEmpty { out.append(info.developers.joined(separator: ", ")) }
            if let y = info.year, y != "TBA" { out.append(y) }
            if let m = info.lengthMinutes, m > 0 { out.append("~\(max(1, Int((Double(m) / 60).rounded()))) hours") }
            if let r = info.rating { out.append("★ " + String(format: "%.2f", r / 10)) }
        }
        if game.playSeconds > 0 {
            var played = "Played \(Format.playtime(game.playSeconds))"
            // Rough progress against VNDB's estimated length.
            if let m = game.vndb?.lengthMinutes, m > 0 {
                played += " · \(min(100, Int(game.playSeconds / 60 / Double(m) * 100)))%"
            }
            out.append(played)
            let n = lib.sessions(of: game.id).count
            if n > 0 { out.append(n == 1 ? "1 session" : "\(n) sessions") }
        } else {
            out.append("Not played yet")
        }
        return out
    }
}

struct TagButton: View {
    let tag: String
    var ero = false
    var active = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(tag)
                .font(.system(size: 11))
                .foregroundStyle(active || hover ? Color.white : ero ? Color(hex: 0xF9A8D4) : Color.kMuted)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(active ? Color.kAccent : hover ? Color.kLine : Color.kPanel2))
                .overlay(Capsule().strokeBorder(ero ? Color(hex: 0xF472B6).opacity(0.5) : Color.kLine))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if !row.items.isEmpty && row.width + spacing + size.width > width {
                let y = row.y + row.height + spacing
                rows.append(row)
                row = Row(y: y)
            }
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

struct FlowChips: View {
    let items: [String]
    var body: some View {
        WrapLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Chip { Text(item).foregroundStyle(Color.kText).lineLimit(1) }
            }
        }
    }
}

/// Search VNDB and pick the right entry for a game.
struct VNDBSheet: View {
    @EnvironmentObject var lib: Library
    @Environment(\.dismiss) private var dismiss
    let id: UUID

    @State private var query = ""
    @State private var results: [VNDB.Result] = []
    @State private var searching = false
    @State private var error: String?
    @State private var rename = false
    @State private var applying: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fetch from VNDB")
                .font(.system(size: 18, weight: .bold))
            HStack {
                TextField("Search by title", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search() } }
                Button("Search") { Task { await search() } }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
            }
            Toggle("Use VNDB's title as the name", isOn: $rename)
                .font(.system(size: 12))

            ZStack {
                if searching {
                    ProgressView()
                } else if let error {
                    Text(error).foregroundStyle(Color.kHinomaru).font(.system(size: 12))
                } else if results.isEmpty {
                    Text("No results. Try a shorter title, or the Japanese one.")
                        .foregroundStyle(.secondary).font(.system(size: 12))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(results) { r in row(r) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Text("Data from vndb.org")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 600, height: 560)
        .task {
            if let g = lib.games.first(where: { $0.id == id }) {
                query = VNDB.query(from: g.name)
                await search()
            }
        }
    }

    private func row(_ r: VNDB.Result) -> some View {
        let current = lib.games.first(where: { $0.id == id })?.vndb?.id == r.id
        return HStack(spacing: 12) {
            AsyncImage(url: r.image.flatMap { URL(string: $0.url) }) { phase in
                if let img = phase.image {
                    img.resizable().scaledToFill().blur(radius: r.explicitCover ? 10 : 0)
                } else {
                    Color.kPanel2
                }
            }
            .frame(width: 54, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(r.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let alt = r.alttitle { Text(alt).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                Text([r.developers.map(\.name).joined(separator: ", "), r.year ?? ""]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if applying == r.id {
                ProgressView().controlSize(.small)
            } else if current {
                Label("Selected", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(Color.kDone)
            }
            Button("Select") {
                applying = r.id
                Task {
                    await lib.apply(r, to: id, rename: rename)
                    dismiss()
                }
            }
            .disabled(applying != nil)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(current ? Color.kAccent.opacity(0.15) : Color.kPanel2.opacity(0.6)))
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        error = nil
        defer { searching = false }
        do {
            results = try await VNDB.search(q)
        } catch {
            results = []
            self.error = "Couldn't search VNDB: \(error.localizedDescription)"
        }
    }
}
