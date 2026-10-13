import GameController
import SwiftUI

/// Full-screen browsing from the sofa: big covers in a row, driven by the
/// arrow keys or a game controller. Return / A plays, Esc / B leaves.
struct CouchView: View {
    @EnvironmentObject var lib: Library
    let close: () -> Void

    @State private var index = 0
    @State private var keyMonitor: Any?
    @State private var lastStick = Date.distantPast

    private var games: [Game] { lib.sorted(.recent, filter: "") }

    var body: some View {
        let list = games
        let current = list.indices.contains(index) ? list[index] : nil
        ZStack {
            // The backdrop is drawn inside a fixed-size layer so a large image
            // can't grow the view past the window.
            Color.black
                .overlay {
                    if let current, let img = lib.blurredImage(for: current) {
                        Image(nsImage: img).resizable().scaledToFill()
                            .opacity(0.45)
                            .animation(.easeInOut(duration: 0.3), value: current.id)
                    }
                }
                .clipped()
            LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    Text("VN Library").font(.system(size: 20, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Text("←  →  choose     ⏎ / Ⓐ  play     esc / Ⓑ  back")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                if let current { details(current) }
                carousel(list)
            }
            .padding(48)

            if list.isEmpty {
                Text("No games to show.").font(.title2).foregroundStyle(.white.opacity(0.7))
            }
        }
        .ignoresSafeArea()
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    private func details(_ game: Game) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(lib.displayName(game))
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
            HStack(spacing: 14) {
                if let st = game.status { StatusBadge(status: st, rating: game.userRating) }
                if let dev = game.vndb?.developers.first { Text(dev) }
                if let y = game.vndb?.year { Text(y) }
                if game.playSeconds > 0 { Text("Played \(Format.playtime(game.playSeconds))") }
                if lib.running[game.id] != nil { Text("Running").foregroundStyle(Color.kDone) }
            }
            .font(.system(size: 16))
            .foregroundStyle(.white.opacity(0.75))
            if let d = game.vndb?.description {
                Text(d)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(3)
                    .frame(maxWidth: 900, alignment: .leading)
            }
        }
    }

    private func carousel(_ list: [Game]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 28) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, game in
                        CoverView(game: game)
                            .frame(width: i == index ? 230 : 180, height: i == index ? 307 : 240)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(i == index ? Color.white : Color.clear, lineWidth: 3))
                            .shadow(color: .black.opacity(0.6), radius: i == index ? 24 : 8, y: 10)
                            .opacity(i == index ? 1 : 0.6)
                            .id(i)
                            .onTapGesture { if i == index { play() } else { index = i } }
                    }
                }
                .padding(.vertical, 20)
                .padding(.horizontal, 6)
                .frame(height: 350, alignment: .bottom)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: index)
            }
            .onChange(of: index) { _, i in withAnimation { proxy.scrollTo(i, anchor: .center) } }
        }
    }

    // MARK: Input

    private func move(_ step: Int) {
        let n = games.count
        guard n > 0 else { return }
        index = (index + step + n) % n
    }

    private func play() {
        let list = games
        guard list.indices.contains(index) else { return }
        lib.launch(list[index])
    }

    private func start() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            switch e.keyCode {
            case 123, 126: move(-1); return nil       // ← ↑
            case 124, 125: move(1); return nil        // → ↓
            case 36, 76, 49: play(); return nil       // return, enter, space
            case 53: close(); return nil              // esc
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
        pad.dpad.left.pressedChangedHandler = { _, _, p in if p { move(-1) } }
        pad.dpad.right.pressedChangedHandler = { _, _, p in if p { move(1) } }
        pad.buttonA.pressedChangedHandler = { _, _, p in if p { play() } }
        pad.buttonB.pressedChangedHandler = { _, _, p in if p { close() } }
        pad.leftThumbstick.valueChangedHandler = { _, x, _ in
            // Treat the stick like a d-pad, at most a step every 0.25 s.
            guard abs(x) > 0.6, Date().timeIntervalSince(lastStick) > 0.25 else { return }
            lastStick = Date()
            move(x > 0 ? 1 : -1)
        }
    }

    private func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        GCController.stopWirelessControllerDiscovery()
        for c in GCController.controllers() {
            guard let pad = c.extendedGamepad else { continue }
            pad.dpad.left.pressedChangedHandler = nil
            pad.dpad.right.pressedChangedHandler = nil
            pad.buttonA.pressedChangedHandler = nil
            pad.buttonB.pressedChangedHandler = nil
            pad.leftThumbstick.valueChangedHandler = nil
        }
    }
}
