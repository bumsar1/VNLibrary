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
    @State private var sheet: SheetKind?
    @State private var showSettings = false
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if lib.games.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .background(Color.kBackground)
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
        .sheet(item: $sheet) { kind in
            switch kind {
            case .edit(let game): EditSheet(game: game).environmentObject(lib)
            case .info(let id):
                InfoSheet(id: id, open: { sheet = $0 }, filterTag: { tag = $0 }).environmentObject(lib)
            case .vndb(let id): VNDBSheet(id: id).environmentObject(lib)
            }
        }
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
        .task {
            // Test hook: open the first game's info page after VNDB has answered.
            if ProcessInfo.processInfo.environment["VNLIB_OPEN_INFO"] != nil {
                try? await Task.sleep(for: .seconds(2.5))
                if let first = lib.games.first { sheet = .info(first.id) }
            }
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
                Text(lib.games.count == 1 ? "1 game" : "\(lib.games.count) games")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.kMuted)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.kMuted)
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Color.kText)
                    .frame(width: 160)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.kPanel2))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.kLine))

            tagMenu

            Picker("", selection: $sort) {
                ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)

            IconButton(symbol: "plus", help: "Add games (⌘O)") { chooseGames() }
            IconButton(symbol: "gearshape", help: "Settings") { showSettings = true }
        }
        .padding(.horizontal, 24)
        .padding(.top, 34)
        .padding(.bottom, 16)
    }

    private var tagMenu: some View {
        Menu {
            if tag != nil {
                Button("Show all games") { tag = nil }
                Divider()
            }
            let tags = lib.allTags
            if tags.isEmpty {
                Text("No tags yet. Fetch data from VNDB first.")
            }
            ForEach(tags, id: \.name) { t in
                Button("\(t.name)  (\(t.count))") { tag = t.name }
            }
        } label: {
            Label(tag ?? "Tags", systemImage: tag == nil ? "tag" : "tag.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(tag == nil ? Color.kPanel2 : Color.kAccent.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tag == nil ? Color.kLine : Color.kAccent))
        .help("Filter by VNDB tag")
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 230), spacing: 22, alignment: .top)], spacing: 26) {
                ForEach(lib.sorted(sort, filter: search, tag: tag)) { game in
                    GameCard(game: game, open: { sheet = $0 })
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .overlay {
            if lib.sorted(sort, filter: search, tag: tag).isEmpty {
                Text("No games match.")
                    .foregroundStyle(Color.kMuted)
            }
        }
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

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.kText)
                .frame(width: 32, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Color.kLine : Color.kPanel2))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.kLine))
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
                if let img = game.isBlurred ? lib.blurredImage(for: game) : lib.image(for: game) {
                    artwork(img, geo.size)
                    if game.isBlurred {
                        Color.black.opacity(0.25)
                        VStack(spacing: 10) {
                            Image(systemName: "eye.slash").font(.system(size: 24))
                            Text(game.name)
                                .font(.system(size: 14, weight: .semibold))
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(16)
                    }
                } else {
                    LinearGradient(colors: [Color(hex: 0x3B2370), Color(hex: 0x1D1D21)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(game.name)
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
    private var missing: Bool { !lib.exists(game) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                CoverView(game: game)
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
                if missing {
                    VStack {
                        Spacer()
                        Label("Folder missing", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Color.kHinomaru))
                            .foregroundStyle(.white)
                            .padding(10)
                    }
                }
            }
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(coverDrop || hover ? Color.kAccent : Color.kLine, lineWidth: coverDrop ? 3 : 1))
            .shadow(color: .black.opacity(hover ? 0.5 : 0.3), radius: hover ? 14 : 8, y: 6)
            .scaleEffect(hover ? 1.02 : 1)
            .animation(.easeOut(duration: 0.15), value: hover)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { lib.launch(game) }
            .onTapGesture { open(.info(game.id)) }
            .onDrop(of: [.fileURL], delegate: CoverDrop(id: game.id, lib: lib, targeted: $coverDrop))

            VStack(alignment: .leading, spacing: 3) {
                Text(game.name)
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
        guard game.lastPlayed != nil else { return Format.lastPlayed(nil) }
        return "\(Format.lastPlayed(game.lastPlayed)) · \(Format.playtime(game.playSeconds))"
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
        panel.canChooseDirectories = game.kind != .macApp
        panel.canChooseFiles = game.kind == .macApp
        if game.kind == .macApp { panel.allowedContentTypes = [.application] }
        panel.directoryURL = URL(fileURLWithPath: game.path).deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            game.path = url.standardizedFileURL.path
            if game.kind != .macApp, lib.isSiglus(url) { game.kind = .siglus }
        }
    }
}

struct SettingsSheet: View {
    @EnvironmentObject var lib: Library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.system(size: 18, weight: .bold))
            Form {
                HStack {
                    TextField("siglus_engine", text: $lib.siglusEngine)
                        .font(.system(size: 12, design: .monospaced))
                    Button("Choose…") { choose() }
                }
                Label(lib.engineFound ? "Found" : "Not found at that path",
                      systemImage: lib.engineFound ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(lib.engineFound ? Color.kDone : Color.kHinomaru)
            }
            .formStyle(.grouped)
            Text("Used for every Siglus game (Key games like Summer Pockets, Clannad, …).")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Form {
                Toggle("Fetch cover and info from VNDB when a game is added", isOn: $lib.autoVNDB)
                Toggle("Show sexual-content tags (pink)", isOn: $lib.showEroTags)
            }
            .formStyle(.grouped)
            HStack {
                Button("Open Library Folder") { NSWorkspace.shared.open(lib.supportDir) }
                Spacer()
                Button("Reset") { lib.siglusEngine = Library.defaultEngine }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
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
}

enum SheetKind: Identifiable {
    case edit(Game), info(UUID), vndb(UUID)
    var id: String {
        switch self {
        case .edit(let g): return "edit-\(g.id)"
        case .info(let id): return "info-\(id)"
        case .vndb(let id): return "vndb-\(id)"
        }
    }
}
