import AppKit
import Foundation
import SwiftUI

/// The app that does dictionary lookups (and OCR where a game has no text
/// hook) next to the games. VN Library only launches the games and serves
/// their text; Kimochi is the recommended reader.
enum TextTool: String, CaseIterable, Identifiable {
    case kimochi, meikipop, off
    var id: String { rawValue }

    var label: String {
        switch self {
        case .kimochi: return "Kimochi (recommended)"
        case .meikipop: return "Meikipop"
        case .off: return "Off"
        }
    }

    /// The saved choice. Before this setting existed there was only the text
    /// hook switch: turned off, it means off; otherwise Kimochi.
    static var current: TextTool {
        let d = UserDefaults.standard
        if let raw = d.string(forKey: "textTool"), let t = TextTool(rawValue: raw) { return t }
        if d.object(forKey: "textHook") as? Bool == false { return .off }
        return .kimochi
    }
}

/// Kimochi (kimochiapp.com): free, open-source lookups, OCR and Anki cards.
/// It reads our text hook as a texthooker at ws://localhost:6677.
enum Kimochi {
    static let bundleID = "dev.kimochi.app"
    static let site = URL(string: "https://kimochiapp.com")!
    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
}

/// Lines VN Library hears on the text hook itself, so characters read,
/// reading speed and kanji stats work without Meikipop. Same format as
/// Meikipop's read log ({"t", "pid", "lines"}), so one reader counts both.
enum HookLog {
    static func folder(in supportDir: URL) -> URL { supportDir.appendingPathComponent("hook-log") }

    static func append(_ text: String, at t: Double, in folder: URL) {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.locale = Locale(identifier: "en_US_POSIX")
        let file = folder.appendingPathComponent(day.string(from: Date(timeIntervalSince1970: t)) + ".jsonl")
        guard var line = try? JSONSerialization.data(withJSONObject: ["t": t, "lines": [text]]) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            try? line.write(to: file)
        }
    }
}

extension Library {
    static var textHookPort: String { ProcessInfo.processInfo.environment["VNLIB_TEXTHOOK_PORT"] ?? "6677" }

    /// Listens to the running game's text hook (as a second client next to
    /// Kimochi) and logs each finished line. Reconnects while the game runs.
    func listenToTextHook(_ id: UUID) {
        guard textTool == .kimochi, hookListeners[id] == nil,
              let url = URL(string: "ws://127.0.0.1:\(Self.textHookPort)/json") else { return }
        let folder = HookLog.folder(in: supportDir)
        hookListeners[id] = Task { @MainActor in
            while !Task.isCancelled, running[id] != nil {
                let socket = URLSession.shared.webSocketTask(with: url)
                socket.resume()
                while !Task.isCancelled {
                    guard let msg = try? await socket.receive() else { break }
                    let data: Data?
                    switch msg {
                    case .string(let s): data = s.data(using: .utf8)
                    case .data(let d): data = d
                    @unknown default: data = nil
                    }
                    guard let data,
                          let ev = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          ev["kind"] as? String == "line",
                          let text = ev["text"] as? String, !text.isEmpty else { continue }
                    HookLog.append(text, at: Date().timeIntervalSince1970, in: folder)
                }
                socket.cancel(with: .goingAway, reason: nil)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// Settings: which app reads along (Kimochi, Meikipop or nothing).
struct TextToolSection: View {
    @EnvironmentObject var lib: Library
    @State private var kimochiInstalled = Kimochi.appURL != nil

    var body: some View {
        Section {
            Picker("Lookups and OCR", selection: $lib.textTool) {
                ForEach(TextTool.allCases) { Text($0.label).tag($0) }
            }
            switch lib.textTool {
            case .kimochi:
                if kimochiInstalled {
                    Toggle("Open Kimochi with every game", isOn: $lib.openKimochi)
                } else {
                    HStack {
                        Label("Kimochi isn't installed", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Spacer()
                        Link("Get Kimochi (free)", destination: Kimochi.site)
                        Button("Check Again") { kimochiInstalled = Kimochi.appURL != nil }
                    }
                }
                address
            case .meikipop:
                address
            case .off:
                EmptyView()
            }
        } header: {
            Text("Text & lookups")
        } footer: {
            Text(footer)
        }
    }

    private var address: some View {
        LabeledContent("Text hook address") {
            Text("ws://localhost:\(Library.textHookPort)").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
        }
    }

    private var footer: String {
        switch lib.textTool {
        case .kimochi:
            return "Kimochi (kimochiapp.com, free and open source) does the dictionary lookups, Anki cards and OCR. Siglus, KiriKiri and BGI games send their text straight from the engine to the address above, no OCR needed: in Kimochi choose Change source → WebSocket (its default address is this one). For other games (Wine, Mac apps) pick the game's window as the source and Kimochi uses OCR. VN Library listens to the same text to count characters read, reading speed and kanji."
        case .meikipop:
            return "Meikipop does the lookups. It reads the text hook of Siglus, KiriKiri and BGI games and OCRs the rest; characters read come from its text log."
        case .off:
            return "No text hook, no reader app and no characters read. For when you use another tool. Applies the next time a game starts."
        }
    }
}
