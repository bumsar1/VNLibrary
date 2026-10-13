import SwiftUI

/// The play tracker: totals, a year of days as a heatmap, top games and every session.
struct ActivityView: View {
    @EnvironmentObject var lib: Library
    let open: (SheetKind) -> Void
    @State private var selectedDay: Date?
    @State private var showAllDays = false

    private let cal = Library.calendar

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                tiles
                HStack(spacing: 12) {
                    if lib.weeklyGoal > 0 {
                        GoalTile(seconds: lib.seconds(since: cal.dateInterval(of: .weekOfYear, for: Date())!.start),
                                 goalHours: lib.weeklyGoal)
                    }
                    if lib.dailyCharGoal > 0 {
                        CharGoalTile(chars: lib.charsToday(), goal: lib.dailyCharGoal)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        reviewButton
                        kanjiButton
                    }
                    if lib.weeklyGoal == 0 && lib.dailyCharGoal == 0 { Spacer() }
                }
                section("Last 12 months") {
                    Heatmap(totals: lib.dayTotals(), selected: $selectedDay)
                }
                ReadingSpeedSection()
                let top = topGames()
                if !top.isEmpty {
                    section("Top games · last 30 days") { topList(top) }
                }
                sessionLog
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    // MARK: Tiles

    private var tiles: some View {
        let now = Date()
        let today = cal.startOfDay(for: now)
        let week = cal.dateInterval(of: .weekOfYear, for: now)!.start
        let month = cal.dateInterval(of: .month, for: now)!.start
        let streak = lib.streak()
        return HStack(spacing: 12) {
            StatTile(label: "Today", value: Format.short(lib.seconds(since: today)))
            StatTile(label: "This week", value: Format.short(lib.seconds(since: week)))
            StatTile(label: "This month", value: Format.short(lib.seconds(since: month)))
            StatTile(label: "All time", value: Format.short(lib.games.reduce(0) { $0 + $1.playSeconds }))
            StatTile(label: "Streak", value: streak == 1 ? "1 day" : "\(streak) days")
            StatTile(label: lib.readingSpeed().map { "Read this week · \(Count.short(Int($0)))/h" } ?? "Read this week",
                     value: "\(Count.short(lib.charsRead(since: week))) chars")
            StatTile(label: "Sessions", value: "\(lib.sessions.count)")
        }
    }

    private var reviewButton: some View {
        Button {
            open(.review(cal.component(.year, from: Date())))
        } label: {
            Label("\(String(cal.component(.year, from: Date()))) in Review", systemImage: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.kPanel))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.kLine))
        }
        .buttonStyle(.plain)
    }

    private var kanjiButton: some View {
        Button { open(.kanji(nil)) } label: {
            Label("Kanji you've met", systemImage: "character.ja")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.kPanel))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.kLine))
        }
        .buttonStyle(.plain)
    }

    // MARK: Top games

    private func topGames() -> [(game: Game, seconds: Double)] {
        let since = cal.date(byAdding: .day, value: -30, to: Date())!
        return lib.visibleGames
            .map { ($0, lib.seconds(since: since, game: $0.id)) }
            .filter { $0.1 >= 60 }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
            .map { (game: $0.0, seconds: $0.1) }
    }

    private func topList(_ top: [(game: Game, seconds: Double)]) -> some View {
        let maxSeconds = top.first?.seconds ?? 1
        return VStack(spacing: 8) {
            ForEach(top, id: \.game.id) { item in
                HStack(spacing: 12) {
                    Thumb(game: item.game)
                    Text(lib.displayName(item.game))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.kText)
                        .lineLimit(1)
                        .frame(width: 220, alignment: .leading)
                    GeometryReader { geo in
                        Capsule().fill(Color.kAccent)
                            .frame(width: max(6, geo.size.width * item.seconds / maxSeconds), height: 8)
                            .frame(maxHeight: .infinity)
                    }
                    .frame(height: 40)
                    Text(Format.playtime(item.seconds))
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Color.kMuted)
                        .frame(width: 90, alignment: .trailing)
                }
                .contentShape(Rectangle())
                .onTapGesture { open(.info(item.game.id)) }
            }
        }
    }

    // MARK: Session log

    private var sessionLog: some View {
        var byDay: [Date: [PlaySession]] = [:]
        let hidden = Set(lib.games.filter { lib.discreet && $0.isAdult }.map(\.id))
        for s in lib.sessions where !hidden.contains(s.gameID) {
            byDay[cal.startOfDay(for: s.start), default: []].append(s)
        }
        var days = byDay.keys.sorted(by: >)
        if let selectedDay { days = days.filter { $0 == selectedDay } }
        let limited = !showAllDays && selectedDay == nil && days.count > 14
        if limited { days = Array(days.prefix(14)) }

        return section(selectedDay.map { "Sessions · " + Format.day($0) } ?? "Sessions") {
            VStack(alignment: .leading, spacing: 18) {
                if selectedDay != nil {
                    Button("Show all days") { selectedDay = nil }
                        .buttonStyle(.link)
                }
                if days.isEmpty {
                    Text(lib.sessions.isEmpty
                         ? "No sessions yet. Start a game from the library and it's tracked here — every day you play and how long each session lasted."
                         : "No sessions on this day.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.kMuted)
                }
                ForEach(days, id: \.self) { day in
                    let list = (byDay[day] ?? []).sorted { $0.start > $1.start }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(Format.day(day))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.kText)
                            Spacer()
                            Text(Format.playtime(list.reduce(0) { $0 + $1.seconds }))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.kMuted)
                        }
                        ForEach(list) { session in row(session) }
                    }
                }
                if limited {
                    Button("Show older days") { showAllDays = true }
                        .buttonStyle(.link)
                }
            }
        }
    }

    private func row(_ s: PlaySession) -> some View {
        let game = lib.games.first(where: { $0.id == s.gameID })
        let live = lib.openSessions[s.gameID] == s.id
        return HStack(spacing: 12) {
            if let game { Thumb(game: game) }
            Text(game.map(lib.displayName) ?? "Removed game")
                .font(.system(size: 13))
                .foregroundStyle(Color.kText)
                .lineLimit(1)
            Spacer()
            if let c = s.chars, c > 0 {
                Button { open(.readText(s.gameID, s.id)) } label: {
                    Label(s.readTime >= 120 ? "\(Count.short(c)) chars · \(Count.short(Int(Double(c) / (s.readTime / 3600))))/h"
                                           : "\(Count.short(c)) chars", systemImage: "text.alignleft")
                        .font(.system(size: 12)).foregroundStyle(Color.kAccent)
                }
                .buttonStyle(.plain)
                .help("Show the text read in this session")
            }
            Text("\(Format.time(s.start)) – \(live ? "now" : Format.time(s.end))")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.kMuted)
            Group {
                if live {
                    Text("Running").foregroundStyle(Color.kDone)
                } else {
                    Text(Format.playtime(s.seconds)).foregroundStyle(Color.kText)
                }
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.kPanel))
        .contentShape(Rectangle())
        .onTapGesture { if let game { open(.info(game.id)) } }
        .contextMenu {
            if let game { Button("Info") { open(.info(game.id)) } }
            if (s.chars ?? 0) > 0 { Button("Show Text Read") { open(.readText(s.gameID, s.id)) } }
            Button("Delete Session") { lib.deleteSession(s) }.disabled(live)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.kMuted)
            content()
        }
    }
}

struct StatTile: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(Color.kText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.kMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.kPanel))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.kLine))
    }
}

/// Small cover for list rows.
struct Thumb: View {
    let game: Game
    var body: some View {
        CoverView(game: game)
            .frame(width: 30, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// A year of days, one column per week (Monday on top), shaded by play time.
struct Heatmap: View {
    let totals: [Date: Double]
    @Binding var selected: Date?

    private let cal = Library.calendar
    private let cell: CGFloat = 13
    private let gap: CGFloat = 3
    private let weeks = 53

    var body: some View {
        let today = cal.startOfDay(for: Date())
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: today)!.start
        let first = cal.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek)!

        VStack(alignment: .leading, spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: gap) {
                        VStack(alignment: .leading, spacing: gap) {
                            Color.clear.frame(height: 14)
                            ForEach(0..<7) { r in
                                Text(r % 2 == 0 ? ["Mon", "", "Wed", "", "Fri", "", "Sun"][r] : "")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.kMuted)
                                    .frame(width: 26, height: cell, alignment: .leading)
                            }
                        }
                        ForEach(0..<weeks, id: \.self) { c in
                            let weekStart = cal.date(byAdding: .weekOfYear, value: c, to: first)!
                            VStack(spacing: gap) {
                                monthLabel(weekStart, column: c)
                                ForEach(0..<7) { r in
                                    let day = cal.date(byAdding: .day, value: r, to: weekStart)!
                                    square(day, future: day > today)
                                }
                            }
                            .id(c)
                        }
                    }
                    .padding(.trailing, 4)
                }
                .onAppear { proxy.scrollTo(weeks - 1, anchor: .trailing) }
            }
            HStack(spacing: 4) {
                Spacer()
                Text("Less").font(.system(size: 10)).foregroundStyle(Color.kMuted)
                ForEach([0.0, 900, 2700, 5400, 9000], id: \.self) { s in
                    RoundedRectangle(cornerRadius: 3).fill(color(s)).frame(width: cell, height: cell)
                }
                Text("More").font(.system(size: 10)).foregroundStyle(Color.kMuted)
            }
        }
    }

    @ViewBuilder
    private func monthLabel(_ weekStart: Date, column: Int) -> some View {
        // Label the first column of each month.
        let month = cal.component(.month, from: weekStart)
        let prev = cal.component(.month, from: cal.date(byAdding: .weekOfYear, value: -1, to: weekStart)!)
        Text(column > 0 && month != prev ? Format.month(weekStart) : "")
            .font(.system(size: 9))
            .foregroundStyle(Color.kMuted)
            .fixedSize()
            .frame(width: cell, height: 14, alignment: .leading)
    }

    @ViewBuilder
    private func square(_ day: Date, future: Bool) -> some View {
        if future {
            Color.clear.frame(width: cell, height: cell)
        } else {
            let seconds = totals[day] ?? 0
            RoundedRectangle(cornerRadius: 3)
                .fill(color(seconds))
                .frame(width: cell, height: cell)
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(selected == day ? Color.white : Color.clear, lineWidth: 1.5))
                .help("\(Format.day(day)): \(seconds > 0 ? Format.playtime(seconds) : "no play")")
                .onTapGesture { selected = selected == day ? nil : day }
        }
    }

    private func color(_ seconds: Double) -> Color {
        switch seconds {
        case ..<60: return Color.kPanel2
        case ..<1800: return Color.kAccent.opacity(0.3)
        case ..<3600: return Color.kAccent.opacity(0.5)
        case ..<7200: return Color.kAccent.opacity(0.75)
        default: return Color.kAccent
        }
    }
}

extension Format {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = format
        return f
    }
    private static let dayFormatter = formatter("EEEE d MMMM yyyy")
    private static let timeFormatter = formatter("HH:mm")
    private static let monthFormatter = formatter("MMM")

    static func day(_ date: Date) -> String {
        let cal = Library.calendar
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return dayFormatter.string(from: date)
    }
    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }
    private static let dateFormatter = formatter("d MMM yyyy")
    static func date(_ date: Date) -> String { dateFormatter.string(from: date) }
    static func month(_ date: Date) -> String { monthFormatter.string(from: date) }

    /// Compact total for tiles: "45 min", "3.5 h", "120 h".
    static func short(_ seconds: Double) -> String {
        let h = seconds / 3600
        if h < 1 { return "\(Int(seconds / 60)) min" }
        if h < 10 { return String(format: "%.1f h", h) }
        return "\(Int(h.rounded())) h"
    }
}
