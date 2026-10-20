import Foundation

/// Whether a running game reads its text from the engine (VNLIB_TEXTHOOK) or
/// Meikipop has to fall back on OCR.
enum TextHookState: Equatable {
    case checking   // started; waiting for the engine's WebSocket
    case engine     // the game (or its helper) serves ws://127.0.0.1:6677
    case ocr        // no hook: Meikipop reads the screen with OCR
    case off        // the Text hook switch is off

    var label: String {
        switch self {
        case .checking: return "Looking for a text hook…"
        case .engine: return "Text hook: engine text, no OCR"
        case .ocr: return "No text hook: Meikipop uses OCR"
        case .off: return "Text hook off: Meikipop uses OCR"
        }
    }
    var symbol: String {
        switch self {
        case .checking: return "hourglass"
        case .engine: return "checkmark.circle.fill"
        case .ocr, .off: return "eye"
        }
    }
}

extension Library {
    /// Engines we build with VNLIB_TEXTHOOK (siglus_engine, KiriKiri and BGI Player).
    static func mayHaveTextHook(_ kind: LaunchKind) -> Bool {
        switch kind {
        case .siglus, .kirikiri, .bgi: return true
        default: return false
        }
    }

    /// After a launch: watch for up to a minute whether the game's process
    /// tree listens on the text hook port.
    func watchTextHook(_ id: UUID, pid: pid_t?) {
        guard let game = games.first(where: { $0.id == id }) else { return }
        guard textHook else { textHookState[id] = .off; return }
        guard Self.mayHaveTextHook(game.kind), let pid, pid > 0 else { textHookState[id] = .ocr; return }
        textHookState[id] = .checking
        Task {
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard running[id] != nil else { return }
                if await Self.textHookOwner(within: pid) {
                    textHookState[id] = .engine
                    return
                }
            }
            if running[id] != nil { textHookState[id] = .ocr }
        }
    }

    /// True when the process listening on the hook port is pid or one of its
    /// descendants (KiriKiri Player's kp-texthook is a child of the engine).
    nonisolated static func textHookOwner(within pid: pid_t) async -> Bool {
        let port = ProcessInfo.processInfo.environment["VNLIB_TEXTHOOK_PORT"] ?? "6677"
        let out = await EngineUpdate.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"],
                                          in: URL(fileURLWithPath: "/")).1
        let owners = Set(out.split(whereSeparator: \.isNewline).compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) })
        guard !owners.isEmpty else { return false }
        if owners.contains(pid) { return true }
        var queue = [pid], seen = Set<pid_t>()
        while let p = queue.popLast(), seen.insert(p).inserted {
            let kids = Processes.descendants(of: p)
            if !owners.isDisjoint(with: kids) { return true }
            queue.append(contentsOf: kids)
        }
        return false
    }
}
