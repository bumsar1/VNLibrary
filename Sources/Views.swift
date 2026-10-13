import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Reads file URLs out of a drop.
func loadFileURLs(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
    let group = DispatchGroup()
    var urls: [URL] = []
    let lock = NSLock()
    for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            defer { group.leave() }
            var url: URL?
            if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            else if let u = item as? URL { url = u }
            if let url { lock.lock(); urls.append(url); lock.unlock() }
        }
    }
    group.notify(queue: .main) { done(urls) }
}

private let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "gif", "heic", "ico", "icns", "tif", "tiff", "bmp"]

struct ContentView: View {
    @EnvironmentObject var lib: Library
    @AppStorage("sort") private var sort: SortOrder = .recent
    @State private var search = ""
    @State private var tag: String?
    @State private var status: PlayStatus?
    @State private var collection: String?
    @State private var installed: Bool?
    @State private var couch = false
    @State private var sheet: SheetKind?
    @State private var showSettings = false
    @State private var dropping = false
    @State private var mode: Mode = .library

    enum Mode: String, CaseIterable { case library = "Library", discover = "Discover", activity = "Activity" }

    var body: some View {
        mainColumn
            .sheet(item: $sheet) { kind in sheetView(kind) }
            .sheet(isPresented: $showSettings) {
                SettingsSheet().environmentObject(lib)
            }
            .alert("VN Library", isPresented: Binding(
                get: { lib.alert != nil }, set: { if !$0 { lib.alert = nil } })
            ) {
                Button("OK") { lib.alert = nil }
            } message: {
                Text(lib.alert ?? "")
            }
            .onReceive(NotificationCenter.default.publisher(for: .addGames)) { _ in chooseGames() }
            .onReceive(NotificationCenter.default.publisher(for: .randomGame)) { _ in pickRandom() }
            .onReceive(NotificationCenter.default.publisher(for: .showDeveloper)) { _ in
                sheet = nil
                mode = .discover
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleCouch)) { _ in setCouch(!couch) }
            .task { await testHooks() }
    }

    @ViewBuilder
    private func sheetView(_ kind: SheetKind) -> some View {
        switch kind {
        case .edit(let game): EditSheet(game: game).environmentObject(lib)
        case .info(let id):
            InfoSheet(id: id, open: { sheet = $0 }, filterTag: { tag = $0; mode = .library }).environmentObject(lib)
        case .vndb(let id): VNDBSheet(id: id).environmentObject(lib)
        case .newCollection(let id): NewCollectionSheet(id: id).environmentObject(lib)
        case .discover(let r): DiscoverSheet(result: r, open: { sheet = $0 }).environmentObject(lib)
        case .wine(let g): WineTrySheet(game: g).environmentObject(lib)
        case .review(let y): YearReviewSheet(year: y, open: { sheet = $0 }).environmentObject(lib)
        }
    }

    private func testHooks() async {
        let env = ProcessInfo.processInfo.environment
        if env["VNLIB_MODE"] == "activity" { mode = .activity }
        if env["VNLIB_MODE"] == "couch" { couch = true }
        if env["VNLIB_MODE"] == "settings" { showSettings = true }
        if env["VNLIB_MODE"] == "discover" { mode = .discover }
        if env["VNLIB_MODE"] == "review" { mode = .activity; sheet = .review(Library.calendar.component(.year, from: Date())) }
        if env["VNLIB_MODE"] == "wine", let g = lib.games.first(where: { $0.kind == .siglus }) { sheet = .wine(g) }
        // Open the first game's info page after VNDB has answered.
        if env["VNLIB_OPEN_INFO"] != nil {
            try? await Task.sleep(for: .seconds(2.5))
            if let first = lib.games.first { sheet = .info(first.id) }
        }
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            header
            if mode == .library && (tag != nil || status != nil || collection != nil || installed != nil) { filterChips }
            if mode == .activity {
                ActivityView(open: { sheet = $0 })
            } else if mode == .discover {
                DiscoverView(open: { sheet = $0 })
            } else if lib.games.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .background(Color.kBackground)
        .overlay {
            if couch {
                CouchView(close: { setCouch(false) }).environmentObject(lib)
                    .transition(.opacity)
            }
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.kAccent, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            loadFileURLs(providers) { add($0) }
            return true
        }
    }

    private var engineUpdateAvailable: Bool {
        if case .available = lib.engineUpdate { return true }
        return false
    }

    private func pickRandom() {
        guard let g = lib.randomPick() else {
            lib.alert = "Nothing to pick from. Mark some games as “Plan to play” first."
            return
        }
        mode = .library
        sheet = .info(g.id)
    }

    /// Couch mode takes the window full screen and leaves it again on exit.
    private func setCouch(_ on: Bool) {
        withAnimation(.easeInOut(duration: 0.25)) { couch = on }
        if let w = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }),
           w.styleMask.contains(.fullScreen) != on {
            w.toggleFullScreen(nil)
        }
    }

    private func add(_ urls: [URL]) {
        let needCommand = lib.add(urls: urls)
        if let first = needCommand.first { sheet = .edit(first) }
    }

    private func chooseGames() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application, .folder]
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Add"
        panel.message = "Choose game folders or Mac apps"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("VN Library")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.kText)
                let count = lib.visibleGames.count
                Text(count == 1 ? "1 game" : "\(count) games")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.kMuted)
            }
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .padding(.leading, 14)
            Spacer()
            if mode == .library {
                libraryControls
                IconButton(symbol: "dice", help: "Pick a random game to play (⌘R)") { pickRandom() }
                IconButton(symbol: "tv", help: "Couch mode (⌘⇧F)") { setCouch(true) }
            }
            IconButton(symbol: lib.discreet ? "eye.slash.fill" : "eye",
                       help: lib.discreet ? "Discreet mode is on (⌘⇧D)" : "Discreet mode (⌘⇧D)",
                       active: lib.discreet) { lib.discreet.toggle() }
            IconButton(symbol: "plus", help: "Add games (⌘O)") { chooseGames() }
            IconButton(symbol: "gearshape", help: engineUpdateAvailable ? "Settings — a siglus_engine update is available" : "Settings") { showSettings = true }
                .overlay(alignment: .topTrailing) {
                    if engineUpdateAvailable {
                        Circle().fill(Color.kAccent).frame(width: 9, height: 9).offset(x: 2, y: -2)
                    }
                }
        }
        .padding(.horizontal, 24)
        .padding(.top, 34)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var libraryControls: some View {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.kMuted)
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Color.kText)
                    .frame(width: 140)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.kPanel2))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.kLine))

            filterMenu
    }

    private var activeFilters: Int { [tag != nil, status != nil, collection != nil, installed != nil].filter { $0 }.count }

    private var filterMenu: some View {
        Menu {
            Picker("Sort by", selection: $sort) {
                ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Menu("Status") {
                ForEach(PlayStatus.allCases) { st in
                    Toggle(st.label, isOn: Binding(get: { status == st }, set: { status = $0 ? st : nil }))
                }
            }
            Menu("Installed") {
                Toggle("Installed — ready to play", isOn: Binding(get: { installed == true }, set: { installed = $0 ? true : nil }))
                Toggle("Not installed", isOn: Binding(get: { installed == false }, set: { installed = $0 ? false : nil }))
            }
            Menu("Collection") {
                let all = lib.allCollections
                if all.isEmpty { Text("No collections yet. Right-click a game → Collections.") }
                ForEach(all, id: \.self) { c in
                    Toggle(c, isOn: Binding(get: { collection == c }, set: { collection = $0 ? c : nil }))
                }
            }
            Menu("Tag") {
                let tags = lib.allTags
                if tags.isEmpty { Text("No tags yet. Fetch data from VNDB first.") }
                ForEach(tags, id: \.name) { t in
                    Toggle("\(t.name)  (\(t.count))", isOn: Binding(get: { tag == t.name }, set: { tag = $0 ? t.name : nil }))
                }
            }
            if activeFilters > 0 {
                Divider()
                Button("Clear Filters") { tag = nil; status = nil; collection = nil; installed = nil }
            }
        } label: {
            Label(activeFilters > 0 ? "Filter (\(activeFilters))" : "Filter",
                  systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(activeFilters > 0 ? Color.kAccent.opacity(0.35) : Color.kPanel2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(activeFilters > 0 ? Color.kAccent : Color.kLine))
        .help("Sort and filter by status, collection or VNDB tag")
    }

    private var filterChips: some View {
        HStack(spacing: 8) {
            if let status { FilterChip(text: status.label, symbol: status.symbol) { self.status = nil } }
            if let collection { FilterChip(text: collection, symbol: "folder") { self.collection = nil } }
            if let installed {
                FilterChip(text: installed ? "Installed" : "Not installed",
                           symbol: installed ? "checkmark.circle" : "arrow.down.circle") { self.installed = nil }
            }
            if let tag { FilterChip(text: tag, symbol: "tag") { self.tag = nil } }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
    }

    private var grid: some View {
        let list = lib.sorted(sort, filter: search, tag: tag, status: status, collection: collection, installed: installed)
        let ready = list.filter { lib.exists($0) }
        let notReady = list.filter { !lib.exists($0) }
        // Split into what can be played now and the rest, unless only one kind is shown.
        let split = !ready.isEmpty && !notReady.isEmpty
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 230), spacing: 22, alignment: .top)],
                      spacing: 26, pinnedViews: []) {
                if split {
                    Section { cards(ready) } header: { sectionHeader("Ready to play", ready.count, "checkmark.circle.fill", Color.kDone) }
                    Section { cards(notReady) } header: {
                        sectionHeader("Not installed", notReady.count, "arrow.down.circle", Color.kMuted).padding(.top, 14)
                    }
                } else {
                    cards(list)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .overlay {
            if list.isEmpty {
                Text("No games match.")
                    .foregroundStyle(Color.kMuted)
            }
        }
    }

    private func cards(_ games: [Game]) -> some View {
        ForEach(games) { game in GameCard(game: game, open: { sheet = $0 }) }
    }

    private func sectionHeader(_ title: String, _ count: Int, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(title.uppercased()).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.kText)
            Text("\(count)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.kMuted)
            Rectangle().fill(Color.kLine).frame(height: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "books.vertical")
                .font(.system(size: 54))
                .foregroundStyle(Color.kAccent)
            Text("Your library is empty")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.kText)
            Text("Drag a game folder or a Mac app in here,\nor click + to choose.")
                .multilineTextAlignment(.center)
                .font(.system(size: 13))
                .foregroundStyle(Color.kMuted)
            Button("Add Games…") { chooseGames() }
                .buttonStyle(AccentButtonStyle())
                .padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct FilterChip: View {
    let text: String
    let symbol: String
    let remove: () -> Void
    var body: some View {
        Button(action: remove) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(text)
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 12))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(Color.kAccent.opacity(0.35)))
            .overlay(Capsule().strokeBorder(Color.kAccent))
        }
        .buttonStyle(.plain)
        .help("Remove filter")
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.kText)
                .frame(width: 32, height: 30)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(active ? Color.kAccent.opacity(0.35) : hover ? Color.kLine : Color.kPanel2))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(active ? Color.kAccent : Color.kLine))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
    }
}

struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Color.kAccent.opacity(configuration.isPressed ? 0.75 : 1)))
    }
}

struct CoverView: View {
    @EnvironmentObject var lib: Library
    let game: Game

    var body: some View {
        GeometryReader { geo in
            ZStack {
                let hidden = game.isBlurred || lib.discreet
                if let img = hidden ? lib.blurredImage(for: game) : lib.image(for: game) {
                    artwork(img, geo.size)
                    if hidden {
                        Color.black.opacity(0.25)
                        VStack(spacing: 10) {
                            Image(systemName: "eye.slash").font(.system(size: 24))
                            Text(lib.displayName(game))
                                .font(.system(size: 14, weight: .semibold))
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(16)
                    }
                } else {
                    LinearGradient(colors: [Color(hex: 0x3B2370), Color(hex: 0x1D1D21)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(lib.displayName(game))
                        .font(.system(size: 17, weight: .bold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.kText)
                        .padding(16)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    @ViewBuilder
    private func artwork(_ img: NSImage, _ size: CGSize) -> some View {
        let ratio = img.size.width / max(img.size.height, 1)
        ZStack {
                    if ratio < 0.9 {
                        // Poster-shaped artwork fills the card.
                        Image(nsImage: img).resizable().scaledToFill()
                            .frame(width: size.width, height: size.height)
                    } else {
                        // Icons and wide art sit on a blurred copy of themselves.
                        Image(nsImage: img).resizable().scaledToFill()
                            .frame(width: size.width, height: size.height)
                            .blur(radius: 28)
                            .overlay(Color.black.opacity(0.35))
                        Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                            .padding(ratio > 1.2 ? 0 : size.width * 0.14)
                            .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
                    }
        }
        .frame(width: size.width, height: size.height)
    }
}

struct GameCard: View {
    @EnvironmentObject var lib: Library
    let game: Game
    let open: (SheetKind) -> Void
    @State private var hover = false
    @State private var coverDrop = false

    private var isRunning: Bool { lib.running[game.id] != nil }
    private var missing: Bool { game.installed && !lib.exists(game) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                CoverView(game: game)
                if let st = game.status {
                    VStack {
                        HStack {
                            StatusBadge(status: st, rating: game.userRating)
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(8)
                }
                if hover || isRunning {
                    Color.black.opacity(isRunning ? 0.45 : 0.3)
                    if isRunning {
                        VStack(spacing: 8) {
                            Text("Running")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .background(Capsule().fill(Color.kDone.opacity(0.9)))
                                .foregroundStyle(.black)
                            if hover {
                                Button("Stop") { lib.stop(game.id) }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                        }
                    } else {
                        Button { lib.launch(game) } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(.white)
                                .frame(width: 64, height: 64)
                                .background(Circle().fill(Color.kAccent))
                                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if missing || !game.installed {
                    VStack {
                        Spacer()
                        Label(missing ? "Folder missing" : "Not installed",
                              systemImage: missing ? "exclamationmark.triangle.fill" : "arrow.down.circle")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(missing ? Color.kHinomaru : Color.black.opacity(0.6)))
                            .foregroundStyle(.white)
                            .padding(10)
                    }
                }
            }
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(coverDrop || (hover && !game.isAdult) ? Color.kAccent : game.isAdult ? Color.kHinomaru : Color.kLine,
                              lineWidth: coverDrop ? 3 : game.isAdult ? 2.5 : 1))
            .overlay(alignment: .bottomTrailing) {
                if game.isAdult && !missing && game.installed { AdultBadge().padding(8) }
            }
            .shadow(color: .black.opacity(hover ? 0.5 : 0.3), radius: hover ? 14 : 8, y: 6)
            .scaleEffect(hover ? 1.02 : 1)
            .animation(.easeOut(duration: 0.15), value: hover)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { lib.launch(game) }
            .onTapGesture { open(.info(game.id)) }
            .onDrop(of: [.fileURL], delegate: CoverDrop(id: game.id, lib: lib, targeted: $coverDrop))

            VStack(alignment: .leading, spacing: 3) {
                Text(lib.displayName(game))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.kText)
                    .lineLimit(2, reservesSpace: true)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.kMuted)
                    .lineLimit(1)
            }
        }
        .onHover { hover = $0 }
        .contextMenu {
            Button(isRunning ? "Running…" : "Play") { lib.launch(game) }.disabled(isRunning)
            if isRunning { Button("Stop") { lib.stop(game.id) } }
            Divider()
            Button("Info") { open(.info(game.id)) }
            Button("Fetch from VNDB…") { open(.vndb(game.id)) }
            Button("Edit…") { open(.edit(game)) }
            Button("Choose Cover…") { chooseCover() }
            Button("Find Cover Automatically") { lib.setCover(game.id, from: nil) }
            Button(game.isBlurred ? "Show Cover" : "Blur Cover") { lib.toggleBlur(game.id) }
            Divider()
            TrackingMenus(game: game, open: open)
            Divider()
            if game.installed && game.kind != .macApp {
                Button("Try with Whisky / CrossOver…") { open(.wine(game)) }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: game.path)])
            }
            if game.kind != .macApp { Button("Show Log") { lib.showLog(game) } }
            Divider()
            Button("Remove from Library") { lib.remove(game.id) }
        }
    }

    private var subtitle: String {
        if isRunning { return "Running now" }
        if lib.fetching.contains(game.id) { return "Fetching from VNDB…" }
        let routes = lib.routeProgress(game).map { " · " + $0 } ?? ""
        guard game.lastPlayed != nil else { return Format.lastPlayed(nil) + routes }
        return "\(Format.lastPlayed(game.lastPlayed)) · \(Format.playtime(game.playSeconds))" + routes
    }

    private func chooseCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "Use as Cover"
        if panel.runModal() == .OK, let url = panel.url { lib.setCover(game.id, from: url) }
    }
}

/// Dropping an image on a card sets its cover; anything else falls through to
/// the window, which adds it as a game.
struct CoverDrop: DropDelegate {
    let id: UUID
    let lib: Library
    @Binding var targeted: Bool

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.image]) || info.hasItemsConforming(to: [.fileURL]) }
    func dropEntered(info: DropInfo) { targeted = true }
    func dropExited(info: DropInfo) { targeted = false }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        let providers = info.itemProviders(for: [.fileURL])
        loadFileURLs(providers) { urls in
            let images = urls.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            if let img = images.first {
                lib.setCover(id, from: img)
            } else {
                let unknown = lib.add(urls: urls)
                if !unknown.isEmpty {
                    lib.alert = "Added. Right-click the new game → Edit to set how it starts."
                }
            }
        }
        return true
    }
}

struct EditSheet: View {
    @EnvironmentObject var lib: Library
    @Environment(\.dismiss) private var dismiss
    @State var game: Game

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Game")
                .font(.system(size: 18, weight: .bold))
            Form {
                TextField("Name", text: $game.name)
                Picker("Launch with", selection: $game.kind) {
                    ForEach(LaunchKind.allCases) { Text($0.label).tag($0) }
                }
                HStack {
                    TextField(game.kind == .macApp ? "App" : "Folder", text: $game.path)
                    Button("Choose…") { choosePath() }
                }
                Section("Open alongside this game") {
                    CompanionList(paths: Binding(get: { game.companions ?? [] },
                                                 set: { game.companions = $0.isEmpty ? nil : $0 }))
                }
                if game.kind == .command {
                    TextField("Command", text: $game.command, axis: .vertical)
                        .lineLimit(2...4)
                        .font(.system(size: 12, design: .monospaced))
                }
            }
            .formStyle(.grouped)

            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Remove from Library", role: .destructive) {
                    lib.remove(game.id)
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    lib.update(game)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private var hint: String {
        switch game.kind {
        case .siglus:
            return "Runs the folder with siglus_engine, which scales the game to fill the window. Set the path to siglus_engine in Settings."
        case .macApp:
            return "Opens a regular Mac app, e.g. a Ren'Py port or a CrossOver shortcut."
        case .command:
            return "Runs in zsh with the game folder as working directory. $GAME_DIR is its path. Example: open -a \"Whisky\" \"$GAME_DIR/game.exe\""
        }
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        // A game added from Discover has no path yet: accept a folder or an app.
        let any = !game.installed
        panel.canChooseDirectories = any || game.kind != .macApp
        panel.canChooseFiles = any || game.kind == .macApp
        if !any && game.kind == .macApp { panel.allowedContentTypes = [.application] }
        if game.installed { panel.directoryURL = URL(fileURLWithPath: game.path).deletingLastPathComponent() }
        if panel.runModal() == .OK, let url = panel.url {
            game.path = url.standardizedFileURL.path
            if any { game.kind = lib.detectKind(of: url) }
            else if game.kind != .macApp, lib.isSiglus(url) { game.kind = .siglus }
        }
    }
}

struct SettingsSheet: View {
    @EnvironmentObject var lib: Library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.system(size: 18, weight: .bold))
                .padding([.horizontal, .top], 22)
            Form {
                Section {
                    HStack {
                        TextField("siglus_engine", text: $lib.siglusEngine)
                            .font(.system(size: 12, design: .monospaced))
                        Button("Choose…") { choose() }
                    }
                    Label(lib.engineFound ? "Found" : "Not found at that path",
                          systemImage: lib.engineFound ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(lib.engineFound ? Color.kDone : Color.kHinomaru)
                    EngineUpdateRow()
                } header: {
                    Text("Siglus engine")
                } footer: {
                    Text("Used for every Siglus game (Key games like Summer Pockets, Clannad, …).")
                }
                Section("VNDB data") {
                    Toggle("Fetch cover and info from VNDB when a game is added", isOn: $lib.autoVNDB)
                    Toggle("Show sexual-content tags (pink)", isOn: $lib.showEroTags)
                    Toggle("Blur images VNDB flags as suggestive (Discover, galleries)", isOn: $lib.blurSuggestive)
                }
                Section("Japanese") {
                    Toggle("Show original Japanese titles (from VNDB)", isOn: $lib.japaneseTitles)
                    JitenKeyRow()
                }
                Section {
                    CompanionList(paths: $lib.globalCompanions)
                } header: {
                    Text("Open alongside every game")
                } footer: {
                    Text("E.g. Meikipop for OCR lookups. They're closed again when the game quits, unless they were already open. Add apps for a single game under Edit.")
                }
                Section("Goal") {
                    Stepper(value: $lib.weeklyGoal, in: 0...80, step: 1) {
                        Text(lib.weeklyGoal == 0 ? "Weekly play goal: off" : "Weekly play goal: \(Int(lib.weeklyGoal)) hours")
                    }
                }
                Section("Couch mode") {
                    Toggle("Sounds when moving around and selecting", isOn: Binding(
                        get: { UserDefaults.standard.object(forKey: "couchSounds") as? Bool ?? true },
                        set: { UserDefaults.standard.set($0, forKey: "couchSounds"); if $0 { CouchSounds.shared.play(.select) } }))
                }
                Section {
                    Toggle("Discreet mode", isOn: $lib.discreet)
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Blurs every cover and hides adult games and sexual tags. Toggle it any time with ⌘⇧D or the eye button.")
                }
                VNDBAccountSection().environmentObject(lib)
            }
            .formStyle(.grouped)
            HStack {
                Button("Open Library Folder") { NSWorkspace.shared.open(lib.supportDir) }
                Button("Reset Engine Path") { lib.siglusEngine = Library.defaultEngine }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 22)
        }
        .frame(width: 560, height: 640)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { lib.siglusEngine = url.path }
    }
}

extension Notification.Name {
    static let addGames = Notification.Name("VNLibraryAddGames")
    static let randomGame = Notification.Name("VNLibraryRandomGame")
    static let toggleCouch = Notification.Name("VNLibraryToggleCouch")
}

enum SheetKind: Identifiable {
    case edit(Game), info(UUID), vndb(UUID), newCollection(UUID), discover(VNDB.Result), wine(Game), review(Int)
    var id: String {
        switch self {
        case .wine(let g): return "wine-\(g.id)"
        case .review(let y): return "review-\(y)"
        case .discover(let r): return "discover-\(r.id)"
        case .newCollection(let id): return "collection-\(id)"
        case .edit(let g): return "edit-\(g.id)"
        case .info(let id): return "info-\(id)"
        case .vndb(let id): return "vndb-\(id)"
        }
    }
}

/// Connect a VNDB account so status, rating and notes sync to the user's list.
/// A Section, meant to sit inside the settings form.
struct VNDBAccountSection: View {
    @EnvironmentObject var lib: Library
    @State private var token = ""
    @State private var working = false
    @State private var message: String?

    var body: some View {
            Section("VNDB list sync") {
                if let name = lib.vndbUsername, lib.vndbSyncEnabled {
                    LabeledContent("Connected as") {
                        Text(name).foregroundStyle(Color.kDone)
                    }
                    Text("Status, rating, notes and dates are sent to your VNDB list when you change them.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        Button("Import from VNDB") { run { await lib.importFromVNDB() } }
                        Button("Send All to VNDB") { run { await lib.exportToVNDB() } }
                        Spacer()
                        Button("Disconnect", role: .destructive) { lib.disconnectVNDB(); message = nil }
                    }
                    .disabled(working)
                } else {
                    SecureField("API token", text: $token)
                    Text("Create a token on vndb.org under your profile → Applications, with “Access to my list” and “Write to my list” ticked. It's stored in the macOS keychain.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        Button("Open vndb.org") { NSWorkspace.shared.open(URL(string: "https://vndb.org/u/tokens")!) }
                        Spacer()
                        Button("Connect") {
                            run {
                                do { return "Connected as \(try await lib.connectVNDB(token: token))." }
                                catch { return error.localizedDescription }
                            }
                        }
                        .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || working)
                    }
                }
                if working { ProgressView().controlSize(.small) }
                if let message { Text(message).font(.system(size: 11)) }
            }
    }

    private func run(_ job: @escaping () async -> String) {
        working = true
        message = nil
        Task {
            message = await job()
            working = false
            token = ""
        }
    }
}
