import AppKit
import ApplicationServices
import Darwin

/// Puts a launched game's window into macOS full screen through the
/// Accessibility API, so it works for any game (siglus_engine, Mac apps,
/// Wine). Needs VN Library to be allowed under Privacy → Accessibility.
enum FullScreen {
    /// Asks macOS for Accessibility access (shows the system prompt once).
    @discardableResult
    static func ensureAccess(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// Waits for the game's first window (up to ~20 s) and makes it full screen.
    /// `pid` may be a launcher shell; its child processes are tried too.
    static func request(pid: pid_t) {
        guard ensureAccess(prompt: true) else { return }
        Task.detached {
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(500))
                for p in [pid] + Processes.descendants(of: pid) where makeFullScreen(p) { return }
            }
        }
    }

    /// Gives the game the focus. Since macOS 14 an app can't take it by
    /// itself: a game started as a plain child process (KiriKiri Player,
    /// siglus_engine) stays behind VN Library unless VN Library yields to it.
    /// Returns whether the game is now in front.
    @discardableResult
    static func bringForward(_ pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        if app.isActive { return true }
        DispatchQueue.main.sync {
            NSApp.yieldActivation(to: app)
            app.activate(from: .current, options: [])
        }
        return app.isActive
    }

    private static func makeFullScreen(_ pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], let window = windows.first else { return false }
        var current: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &current) == .success,
           (current as? Bool) == true { return true }
        // Bring it forward first; some windows ignore full screen while inactive.
        let front = bringForward(pid)
        // A window that can't be made full screen from outside (non-resizable
        // SDL windows) goes full screen itself via VNLIB_FULLSCREEN. Leave it
        // alone: poking it mid-transition flipped it back out. It can only do
        // that while it's in front, so keep going until it is.
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(window, "AXFullScreen" as CFString, &settable) == .success, !settable.boolValue {
            return front
        }
        return AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanTrue) == .success
    }

}

enum Processes {
    /// Waits up to ~10 s for a process whose executable lives inside the app
    /// bundle, and returns the newest one.
    static func waitForProcess(insideBundle path: String) async -> pid_t? {
        let prefix = URL(fileURLWithPath: path).standardizedFileURL.path + "/Contents/"
        for _ in 0..<20 {
            if let pid = await Task.detached(operation: { newest(withExecutablePrefix: prefix) }).value { return pid }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    private static func newest(withExecutablePrefix prefix: String) -> pid_t? {
        // proc_pidpath gives the exact executable path (ps escapes non-ASCII,
        // and game folders are often Japanese).
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var buf = [CChar](repeating: 0, count: 4096)
        return pids.prefix(Int(max(0, n))).filter { pid in
            guard pid > 0, proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
            return String(cString: buf).hasPrefix(prefix)
        }.max()
    }

    /// Child processes, recursively (zsh → wine → the game).
    static func descendants(of pid: pid_t) -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return [] }
        p.waitUntilExit()
        let kids = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .split(separator: "\n").compactMap { pid_t($0) } ?? []
        return kids + kids.flatMap { descendants(of: $0) }
    }
}
