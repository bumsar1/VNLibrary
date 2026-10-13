import AppKit
import CoreGraphics

/// One stretch of playing a game.
struct PlaySession: Codable, Identifiable, Equatable {
    var id = UUID()
    var gameID: UUID
    var start: Date
    var end: Date
    /// Active time. Lower than end - start when the Mac sat idle mid-session.
    var seconds: Double = 0
    /// Characters read in this session (Meikipop's text log).
    var chars: Int?
}

extension Library {
    /// Time with no keyboard or mouse input after which play time stops
    /// counting (a game left open overnight shouldn't count as played).
    static let idleLimit: TimeInterval = 10 * 60
    /// Sessions shorter than this are dropped (a launch that crashed, a peek).
    static let minimumSession: TimeInterval = 60

    // MARK: Persistence

    func loadSessions() {
        guard let data = try? Data(contentsOf: sessionsFile) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        sessions = (try? dec.decode([PlaySession].self, from: data)) ?? []
        // A session cut off by VN Library quitting is kept up to its last beat;
        // drop the ones that never got past the minimum.
        sessions.removeAll { $0.seconds < Self.minimumSession }
    }

    func saveSessions() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(sessions) {
            try? data.write(to: sessionsFile, options: .atomic)
        }
    }

    // MARK: Recording

    func beginSession(_ gameID: UUID) {
        let now = Date()
        let session = PlaySession(gameID: gameID, start: now, end: now)
        sessions.append(session)
        openSessions[gameID] = session.id
        lastBeat[gameID] = now
        saveSessions()
        if heartbeat == nil {
            // The session is written every beat, so quitting VN Library while a
            // game runs loses at most one beat of play time.
            heartbeat = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.beat() }
            }
        }
    }

    func endSession(_ gameID: UUID) {
        beat(only: gameID)
        defer { processReadLog() }      // after the session is closed, so its text is flushed
        guard let sid = openSessions.removeValue(forKey: gameID) else { return }
        lastBeat[gameID] = nil
        if let s = sessions.first(where: { $0.id == sid }), s.seconds < Self.minimumSession {
            sessions.removeAll { $0.id == sid }
        }
        saveSessions()
        if openSessions.isEmpty {
            heartbeat?.invalidate()
            heartbeat = nil
        }
    }

    private func secondsSinceInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Adds the time since the last beat to each open session, unless the
    /// Mac has been idle long enough that nobody is playing.
    private func beat(only: UUID? = nil) {
        let now = Date()
        let active = secondsSinceInput() < Self.idleLimit
        for (gameID, sid) in openSessions where only == nil || only == gameID {
            let delta = now.timeIntervalSince(lastBeat[gameID] ?? now)
            lastBeat[gameID] = now
            guard let si = sessions.firstIndex(where: { $0.id == sid }) else { continue }
            sessions[si].end = now
            if active {
                sessions[si].seconds += delta
                if let gi = games.firstIndex(where: { $0.id == gameID }) { games[gi].playSeconds += delta }
            }
        }
        saveSessions()
        save()
        if only == nil { processReadLog() }
    }

    // MARK: Editing

    func deleteSession(_ session: PlaySession) {
        guard openSessions[session.gameID] != session.id else { return }
        sessions.removeAll { $0.id == session.id }
        if let gi = games.firstIndex(where: { $0.id == session.gameID }) {
            games[gi].playSeconds = max(0, games[gi].playSeconds - session.seconds)
        }
        saveSessions()
        save()
    }

    // MARK: Statistics

    nonisolated static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2      // weeks start on Monday
        c.locale = Locale(identifier: "en_GB")
        return c
    }

    /// Active seconds per day (keyed by start of day), optionally for one game.
    func dayTotals(game: UUID? = nil) -> [Date: Double] {
        let cal = Self.calendar
        var out: [Date: Double] = [:]
        for s in sessions where game == nil || s.gameID == game {
            out[cal.startOfDay(for: s.start), default: 0] += s.seconds
        }
        return out
    }

    func seconds(since date: Date, game: UUID? = nil) -> Double {
        sessions.filter { $0.start >= date && (game == nil || $0.gameID == game) }.reduce(0) { $0 + $1.seconds }
    }

    /// Days in a row with play, ending today (or yesterday, if today has none yet).
    func streak() -> Int {
        let cal = Self.calendar
        let days = Set(dayTotals().filter { $0.value >= Self.minimumSession }.keys)
        var day = cal.startOfDay(for: Date())
        if !days.contains(day) { day = cal.date(byAdding: .day, value: -1, to: day)! }
        var n = 0
        while days.contains(day) {
            n += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        return n
    }

    func sessions(of game: UUID) -> [PlaySession] {
        sessions.filter { $0.gameID == game }.sorted { $0.start > $1.start }
    }
}
