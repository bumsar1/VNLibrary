import Charts
import Security
import SwiftUI

// MARK: Where you left off

struct LeftOffView: View {
    let lines: [String]
    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("WHERE YOU LEFT OFF").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.kMuted)
                ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                    Text(l)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.kText.opacity(i == lines.count - 1 ? 0.95 : 0.6))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.kPanel2))
        }
    }
}

// MARK: Reading goal and speed

struct CharGoalTile: View {
    let chars: Int
    let goal: Int
    var body: some View {
        let progress = min(1, Double(chars) / Double(max(goal, 1)))
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Color.kPanel2, lineWidth: 6)
                Circle().trim(from: 0, to: progress)
                    .stroke(progress >= 1 ? Color.kDone : Color(hex: 0x60A5FA), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(progress * 100))%").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(Color.kText)
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(Count.short(chars)) / \(Count.short(goal)) chars")
                    .font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(Color.kText)
                Text(progress >= 1 ? "Today's reading goal reached" : "Read today")
                    .font(.system(size: 11)).foregroundStyle(progress >= 1 ? Color.kDone : Color.kMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.kPanel))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.kLine))
    }
}

extension Library {
    /// Characters per hour for each of the last `weeks` weeks (nil where no text was logged).
    func weeklySpeed(weeks: Int = 12) -> [(week: Date, speed: Double)] {
        let cal = Self.calendar
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: Date())!.start
        return (0..<weeks).reversed().compactMap { back in
            let start = cal.date(byAdding: .weekOfYear, value: -back, to: thisWeek)!
            let end = cal.date(byAdding: .weekOfYear, value: 1, to: start)!
            let s = sessions.filter { ($0.chars ?? 0) > 0 && $0.start >= start && $0.start < end }
            let secs = s.reduce(0) { $0 + $1.readTime }
            guard secs >= 300 else { return nil }
            return (start, Double(s.reduce(0) { $0 + ($1.chars ?? 0) }) / (secs / 3600))
        }
    }

    /// Reading speed by time of day, in 3-hour blocks.
    func speedByTimeOfDay() -> [(label: String, speed: Double, hours: Double)] {
        let cal = Self.calendar
        var chars = Array(repeating: 0, count: 8), secs = Array(repeating: 0.0, count: 8)
        for s in sessions where (s.chars ?? 0) > 0 {
            let b = cal.component(.hour, from: s.start) / 3
            chars[b] += s.chars ?? 0
            secs[b] += s.readTime
        }
        return (0..<8).compactMap { b in
            guard secs[b] >= 300 else { return nil }
            return (String(format: "%02d–%02d", b * 3, b * 3 + 3), Double(chars[b]) / (secs[b] / 3600), secs[b] / 3600)
        }
    }

    func charsToday() -> Int { charsRead(since: Self.calendar.startOfDay(for: Date())) }
}

/// Activity section: weekly reading speed and speed by time of day.
struct ReadingSpeedSection: View {
    @EnvironmentObject var lib: Library
    var body: some View {
        let weeks = lib.weeklySpeed()
        let times = lib.speedByTimeOfDay()
        if !weeks.isEmpty {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("READING SPEED · CHARS PER HOUR").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.kMuted)
                    Chart(weeks, id: \.week) { w in
                        LineMark(x: .value("Week", w.week, unit: .weekOfYear), y: .value("Chars/h", w.speed))
                            .foregroundStyle(Color.kAccent)
                            .interpolationMethod(.monotone)
                        PointMark(x: .value("Week", w.week, unit: .weekOfYear), y: .value("Chars/h", w.speed))
                            .foregroundStyle(Color.kAccent)
                            .annotation(position: .top) {
                                Text(Count.short(Int(w.speed))).font(.system(size: 9)).foregroundStyle(Color.kMuted)
                            }
                    }
                    .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(Count.short(Int(d))) } } } }
                    .frame(height: 160)
                }
                .frame(maxWidth: .infinity)
                if times.count >= 2 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("BY TIME OF DAY").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.kMuted)
                        Chart(times, id: \.label) { t in
                            BarMark(x: .value("Time", t.label), y: .value("Chars/h", t.speed))
                                .foregroundStyle(Color(hex: 0x60A5FA))
                        }
                        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(Count.short(Int(d))) } } } }
                        .frame(height: 160)
                    }
                    .frame(width: 320)
                }
            }
        }
    }
}

// MARK: Kanji met vs WaniKani

/// WaniKani: which kanji it teaches at which level, and which you've started.
enum WaniKani {
    private static let service = "dk.cadesign.vnlibrary.wanikani"

    static var token: String? {
        get {
            if ProcessInfo.processInfo.environment["VNLIB_SUPPORT_DIR"] != nil { return nil }
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecReturnData as String: true]
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
            return String(data: d, encoding: .utf8)
        }
        set {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            SecItemDelete(q as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var add = q
            add[kSecValueData as String] = Data(newValue.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    struct Kanji: Codable { let level: Int; var started: Bool; var passed: Bool }

    /// Every WaniKani kanji with its level and your progress, keyed by character.
    static func load(token: String) async throws -> (level: Int, kanji: [String: Kanji]) {
        func get(_ url: String) async throws -> [String: Any] {
            var req = URLRequest(url: URL(string: url)!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("20170710", forHTTPHeaderField: "Wanikani-Revision")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw NSError(domain: "WaniKani", code: (resp as? HTTPURLResponse)?.statusCode ?? 0,
                              userInfo: [NSLocalizedDescriptionKey: "WaniKani rejected the token."])
            }
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        func all(_ first: String) async throws -> [[String: Any]] {
            var out: [[String: Any]] = []
            var next: String? = first
            while let url = next {
                let page = try await get(url)
                out += (page["data"] as? [[String: Any]]) ?? []
                next = (page["pages"] as? [String: Any])?["next_url"] as? String
            }
            return out
        }
        let user = try await get("https://api.wanikani.com/v2/user")
        let level = ((user["data"] as? [String: Any])?["level"] as? Int) ?? 0
        var byID: [Int: (String, Int)] = [:]
        for s in try await all("https://api.wanikani.com/v2/subjects?types=kanji") {
            guard let id = s["id"] as? Int, let d = s["data"] as? [String: Any],
                  let ch = d["characters"] as? String, let lv = d["level"] as? Int else { continue }
            byID[id] = (ch, lv)
        }
        var kanji: [String: Kanji] = [:]
        for (_, v) in byID { kanji[v.0] = Kanji(level: v.1, started: false, passed: false) }
        for a in try await all("https://api.wanikani.com/v2/assignments?subject_types=kanji&started=true") {
            guard let d = a["data"] as? [String: Any], let sid = d["subject_id"] as? Int, let (ch, _) = byID[sid] else { continue }
            kanji[ch]?.started = true
            kanji[ch]?.passed = d["passed_at"] is String
        }
        return (level, kanji)
    }
}

extension Library {
    /// Every kanji in the text you've read (one game, or all), with counts.
    func kanjiMet(game: UUID?) -> [(kanji: String, count: Int)] {
        var counts: [String: Int] = [:]
        for g in games where game == nil || g.id == game {
            for line in readLines(game: g.id) {
                for u in line.text.unicodeScalars where (0x4E00...0x9FFF).contains(u.value) || (0x3400...0x4DBF).contains(u.value) {
                    counts[String(u), default: 0] += 1
                }
            }
        }
        return counts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }
}

struct KanjiSheet: View {
    @EnvironmentObject var lib: Library
    @Environment(\.dismiss) private var dismiss
    let game: UUID?

    @State private var met: [(kanji: String, count: Int)] = []
    @State private var wk: [String: WaniKani.Kanji]?
    @State private var wkLevel = 0
    @State private var tokenInput = ""
    @State private var error: String?
    @State private var loading = false
    @State private var filter = 1     // 0 all, 1 not taught yet, 2 not in WaniKani

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Kanji you've met").font(.system(size: 18, weight: .bold))
                Text(game.flatMap { id in lib.games.first { $0.id == id } }.map(lib.displayName) ?? "All games")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }
            Text("Every kanji in the text Meikipop recorded while you played, counted, and checked against your WaniKani progress.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if let wk {
                let taught = met.filter { wk[$0.kanji]?.started == true }
                let passed = met.filter { wk[$0.kanji]?.passed == true }
                let later = met.filter { wk[$0.kanji] != nil && wk[$0.kanji]?.started != true }
                let outside = met.filter { wk[$0.kanji] == nil }
                HStack(spacing: 10) {
                    StatTile(label: "Kanji met", value: "\(met.count)")
                    StatTile(label: "Taught by WaniKani", value: "\(taught.count)")
                    StatTile(label: "Passed (Guru+)", value: "\(passed.count)")
                    StatTile(label: "Not taught yet", value: "\(later.count)")
                    StatTile(label: "Not in WaniKani", value: "\(outside.count)")
                }
                Picker("", selection: $filter) {
                    Text("Not taught yet").tag(1)
                    Text("Not in WaniKani").tag(2)
                    Text("All").tag(0)
                }
                .pickerStyle(.segmented).labelsHidden()
                let list = filter == 1 ? later : filter == 2 ? outside : met
                grid(list.sorted { filter == 1 ? (wk[$0.kanji]?.level ?? 99, -$0.count) < (wk[$1.kanji]?.level ?? 99, -$1.count) : $0.count > $1.count })
                Text("You're on WaniKani level \(wkLevel). “Not taught yet” is sorted by the level WaniKani teaches it at.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    StatTile(label: "Kanji met", value: "\(met.count)")
                    StatTile(label: "Times seen", value: Count.short(met.reduce(0) { $0 + $1.count }))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add your WaniKani API token to compare with what WaniKani has taught you (wanikani.com → Settings → API Tokens; read-only is enough). It's kept in the keychain.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        SecureField("WaniKani API token", text: $tokenInput).textFieldStyle(.roundedBorder)
                        Button("Connect") {
                            WaniKani.token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            tokenInput = ""
                            Task { await loadWK() }
                        }
                        .disabled(tokenInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color.kHinomaru) }
                }
                grid(met)
            }
            HStack {
                if loading { ProgressView().controlSize(.small) }
                if wk != nil { Button("Disconnect WaniKani") { WaniKani.token = nil; wk = nil } }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 760, height: 640)
        .task {
            met = lib.kanjiMet(game: game)
            if WaniKani.token != nil { await loadWK() }
        }
    }

    private func grid(_ list: [(kanji: String, count: Int)]) -> some View {
        Group {
            if met.isEmpty {
                Text("No text recorded yet. Play with Meikipop open and the kanji you read show up here.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                        ForEach(list, id: \.kanji) { k in
                            VStack(spacing: 2) {
                                Text(k.kanji).font(.system(size: 28))
                                Text("×\(k.count)").font(.system(size: 10)).foregroundStyle(.secondary)
                                if let w = wk?[k.kanji] {
                                    Text("WK \(w.level)").font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(w.passed ? Color.kDone : w.started ? Color.kAccent : Color.kMuted)
                                }
                            }
                            .frame(width: 64, height: 78)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.kPanel2))
                            .onTapGesture {
                                let url = wk?[k.kanji] != nil ? "https://www.wanikani.com/kanji/" : "https://jisho.org/search/"
                                NSWorkspace.shared.open(URL(string: url + k.kanji.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)!)
                            }
                            .help("Open on \(wk?[k.kanji] != nil ? "WaniKani" : "Jisho")")
                        }
                    }
                }
            }
        }
    }

    private func loadWK() async {
        guard let token = WaniKani.token else { return }
        loading = true
        defer { loading = false }
        do {
            let r = try await WaniKani.load(token: token)
            wk = r.kanji
            wkLevel = r.level
            error = nil
        } catch {
            self.error = error.localizedDescription
            WaniKani.token = nil
        }
    }
}
