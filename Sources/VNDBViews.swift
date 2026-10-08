import AppKit
import SwiftUI

/// A game's page: cover, VNDB details and the play button.
struct InfoSheet: View {
    @EnvironmentObject var lib: Library
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    let open: (SheetKind) -> Void
    let filterTag: (String) -> Void

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
            CoverView(game: game)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .frame(width: 240)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.kLine))

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

                if let info {
                    // Description first, tags below it, all in one scroll area so a
                    // long tag list never pushes the text off the page.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(info.description ?? "Ingen beskrivelse på VNDB.")
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
                                .help("Klik på et tag for at vise alle spil med det")
                            }
                        }
                        .padding(.trailing, 8)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(lib.fetching.contains(id) ? "Henter fra VNDB…" : "Ingen VNDB-data endnu.")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.kMuted)
                        if !lib.fetching.contains(id) {
                            Button("Find på VNDB…") { open(.vndb(id)) }
                        }
                    }
                    Spacer()
                }

                HStack {
                    Button {
                        lib.launch(game)
                        dismiss()
                    } label: {
                        Label(lib.running[id] != nil ? "Kører" : "Spil", systemImage: "play.fill")
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(lib.running[id] != nil)
                    .keyboardShortcut(.defaultAction)

                    Menu("Mere") {
                        Button("Hent fra VNDB…") { open(.vndb(id)) }
                        if let info { Button("Åbn på vndb.org") { NSWorkspace.shared.open(info.url) } }
                        Button("Rediger…") { open(.edit(game)) }
                        Button(game.isBlurred ? "Vis cover" : "Blur cover") { lib.toggleBlur(id) }
                        Button("Vis i Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: game.path)])
                        }
                        if info != nil {
                            Divider()
                            Button("Fjern VNDB-data") { lib.forgetVNDB(id) }
                        }
                    }
                    .fixedSize()
                    Spacer()
                    Button("Luk") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(24)
        .frame(width: 760, height: 440)
        .background(Color.kPanel)
    }

    private func facts(_ game: Game) -> [String] {
        var out: [String] = []
        if let info = game.vndb {
            if !info.developers.isEmpty { out.append(info.developers.joined(separator: ", ")) }
            if let y = info.year, y != "TBA" { out.append(y) }
            if let m = info.lengthMinutes, m > 0 { out.append("ca. \(max(1, Int((Double(m) / 60).rounded()))) timer") }
            if let r = info.rating { out.append("★ " + String(format: "%.2f", r / 10)) }
        }
        out.append(game.playSeconds > 0 ? "Spillet \(Format.playtime(game.playSeconds))" : "Ikke spillet endnu")
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
        HStack(spacing: 6) {
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
            Text("Hent fra VNDB")
                .font(.system(size: 18, weight: .bold))
            HStack {
                TextField("Søg efter titel", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search() } }
                Button("Søg") { Task { await search() } }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
            }
            Toggle("Brug VNDB's titel som navn", isOn: $rename)
                .font(.system(size: 12))

            ZStack {
                if searching {
                    ProgressView()
                } else if let error {
                    Text(error).foregroundStyle(Color.kHinomaru).font(.system(size: 12))
                } else if results.isEmpty {
                    Text("Ingen resultater. Prøv en kortere titel, eller den japanske titel.")
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
                Text("Data fra vndb.org")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Annuller") { dismiss() }.keyboardShortcut(.cancelAction)
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
                Label("Valgt", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(Color.kDone)
            }
            Button("Vælg") {
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
            self.error = "Kunne ikke søge på VNDB: \(error.localizedDescription)"
        }
    }
}
