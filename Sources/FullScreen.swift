import AppKit
import ApplicationServices

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
                for p in [pid] + descendants(of: pid) where makeFullScreen(p) { return }
            }
        }
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
        NSRunningApplication(processIdentifier: pid)?.activate()
        return AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanTrue) == .success
    }

    /// Child processes, recursively (zsh → wine → the game).
    private static func descendants(of pid: pid_t) -> [pid_t] {
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
