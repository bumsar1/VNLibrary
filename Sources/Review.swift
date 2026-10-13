import SwiftUI

/// Progress ring for the weekly play goal.
struct GoalTile: View {
    let seconds: Double
    let goalHours: Double

    var body: some View {
        let progress = min(1, seconds / 3600 / goalHours)
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Color.kPanel2, lineWidth: 6)
                Circle().trim(from: 0, to: progress)
                    .stroke(progress >= 1 ? Color.kDone : Color.kAccent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(progress * 100))%").font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.kText)
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(String(format: "%.1f / %g h", seconds / 3600, goalHours))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.kText)
                Text(progress >= 1 ? "Weekly goal reached" : "Weekly goal")
                    .font(.system(size: 11))
                    .foregroundStyle(progress >= 1 ? Color.kDone : Color.kMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.kPanel))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.kLine))
    }
}

/// A year at a glance: totals, records, months, top and finished games.
struct YearReviewSheet: View {
    @EnvironmentObject var lib: Library
    @Environment(\.dismiss) private var dismiss
    @State var year: Int
    let open: (SheetKind) -> Void

    private let cal = Library.calendar

    var body: some View {
        let sessions = lib.sessions.filter { cal.component(.year, from: $0.start) == year }
        let hidden = Set(lib.games.filter { lib.discreet && $0.isAdult }.map(\.id))
        let visible = sessions.filter { !hidden.contains($0.gameID) }
        let total = visible.reduce(0) { $0 + $1.seconds }
        var byDay: [Date: Double] = [:]
        for s in visible { byDay[cal.startOfDay(for: s.start), default: 0] += s.seconds }
        var byGame: [UUID: Double] = [:]
        for s in visible { byGame[s.gameID, default: 0] += s.seconds }
        var byMonth = Array(repeating: 0.0, count: 12)
        for s in visible { byMonth[cal.component(.month, from: s.start) - 1] += s.seconds }
        let best = byDay.max { $0.value < $1.value }
        let longest = visible.max { $0.seconds < $1.seconds }
        let finished = lib.visibleGames.filter { g in g.finished.map { cal.component(.year, from: $0) == year } ?? false }
        let top = byGame.sorted { $0.value > $1.value }.prefix(5).compactMap { e in
            lib.games.first { $0.id == e.key }.map { ($0, e.value) }
        }

        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("\(String(year)) in Review").font(.system(size: 22, weight: .bold))
                Spacer()
                Picker("", selection: $year) {
                    ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                }
                .labelsHidden().frame(width: 100)
            }
            if visible.isEmpty {
                Text("No sessions recorded in \(String(year)).").foregroundStyle(Color.kMuted)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(spacing: 12) {
                            StatTile(label: "Played", value: Format.short(total))
                            StatTile(label: "Days played", value: "\(byDay.count)")
                            StatTile(label: "Sessions", value: "\(visible.count)")
                            StatTile(label: "Finished", value: "\(finished.count)")
                        }
                        HStack(spacing: 12) {
                            StatTile(label: "Longest streak", value: "\(streak(Set(byDay.keys))) days")
                            StatTile(label: best.map { "Best day · " + Format.date($0.key) } ?? "Best day",
                                     value: Format.short(best?.value ?? 0))
                            StatTile(label: "Longest session", value: Format.short(longest?.seconds ?? 0))
                        }
                        months(byMonth)
                        if !top.isEmpty {
                            header("Most played")
                            ForEach(top, id: \.0.id) { g, secs in
                                HStack(spacing: 12) {
                                    Thumb(game: g)
                                    Text(lib.displayName(g)).font(.system(size: 13)).lineLimit(1)
                                    Spacer()
                                    Text(Format.playtime(secs)).font(.system(size: 12, design: .rounded)).foregroundStyle(Color.kMuted)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { open(.info(g.id)) }
                            }
                        }
                        if !finished.isEmpty {
                            header("Finished in \(String(year))")
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(finished) { g in
                                        VStack(alignment: .leading, spacing: 4) {
                                            CoverView(game: g).frame(width: 90, height: 120)
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                            Text(lib.displayName(g)).font(.system(size: 10)).lineLimit(2).frame(width: 90, alignment: .leading)
                                            if let r = g.userRating { Text("\(r)★").font(.system(size: 10)).foregroundStyle(Color.kMuted) }
                                        }
                                        .onTapGesture { open(.info(g.id)) }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.trailing, 6)
                }
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24)
        .frame(width: 720, height: 640)
        .background(Color.kPanel)
    }

    private var years: [Int] {
        let ys = Set(lib.sessions.map { cal.component(.year, from: $0.start) } + [cal.component(.year, from: Date())])
        return ys.sorted(by: >)
    }

    private func streak(_ days: Set<Date>) -> Int {
        var best = 0
        for d in days where !days.contains(cal.date(byAdding: .day, value: -1, to: d)!) {
            var n = 0, cur = d
            while days.contains(cur) { n += 1; cur = cal.date(byAdding: .day, value: 1, to: cur)! }
            best = max(best, n)
        }
        return best
    }

    private func header(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.kMuted)
    }

    private func months(_ m: [Double]) -> some View {
        let peak = max(m.max() ?? 1, 1)
        let names = ["J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D"]
        return VStack(alignment: .leading, spacing: 8) {
            header("By month")
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(0..<12, id: \.self) { i in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(m[i] > 0 ? Color.kAccent : Color.kPanel2)
                            .frame(height: max(4, 110 * m[i] / peak))
                            .help("\(Format.playtime(m[i]))")
                        Text(names[i]).font(.system(size: 10)).foregroundStyle(Color.kMuted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 130, alignment: .bottom)
        }
    }
}
