import SwiftUI

/// VNDB filters for Discover, remembered between launches.
struct DiscoverFilters: Codable, Equatable {
    struct TagRef: Codable, Hashable { let id: String; let name: String }
    enum Released: String, Codable, CaseIterable { case any, thisYear, last12Months, years }

    var languages: Set<String> = ["ja"]      // a release is available in
    var originalLanguage: String?
    var platforms: Set<String> = []
    var lengths: Set<Int> = []
    var minRating: Int?                      // 10–100
    var released: Released = .any
    var yearFrom = 2015
    var yearTo = Calendar.current.component(.year, from: Date())
    var finishedOnly = false
    var tags: [TagRef] = []
    var hideInLibrary = false
    var developer: TagRef?                   // a VNDB producer: "everything by Key"

    static let languageNames: [(String, String)] = [("ja", "Japanese"), ("en", "English"), ("zh-Hans", "Chinese (simplified)"),
                                                    ("zh-Hant", "Chinese (traditional)"), ("ko", "Korean")]
    static let platformNames: [(String, String)] = [("win", "Windows"), ("mac", "Mac"), ("lin", "Linux"), ("ios", "iOS"),
                                                    ("and", "Android"), ("swi", "Switch"), ("ps4", "PS4"), ("ps5", "PS5"), ("web", "Browser")]
    static let lengthNames: [(Int, String)] = [(1, "Very short <2h"), (2, "Short 2–10h"), (3, "Medium 10–30h"),
                                               (4, "Long 30–50h"), (5, "Very long 50h+")]

    /// VNDB filter conditions, to be joined with "and".
    var conditions: [Any] {
        func anyOf(_ field: String, _ values: [Any]) -> Any? {
            if values.isEmpty { return nil }
            return values.count == 1 ? [field, "=", values[0]] : ["or"] + values.map { [field, "=", $0] }
        }
        var out: [Any] = []
        if let c = anyOf("lang", languages.sorted()) { out.append(c) }
        if let o = originalLanguage { out.append(["olang", "=", o]) }
        if let c = anyOf("platform", platforms.sorted()) { out.append(c) }
        if let c = anyOf("length", lengths.sorted()) { out.append(c) }
        if let r = minRating { out.append(["rating", ">=", r]) }
        let year = Calendar.current.component(.year, from: Date())
        switch released {
        case .any: break
        case .thisYear: out.append(["released", ">=", "\(year)-01-01"])
        case .last12Months:
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
            out.append(["released", ">=", f.string(from: Calendar.current.date(byAdding: .year, value: -1, to: Date())!)])
        case .years:
            out.append(["released", ">=", "\(min(yearFrom, yearTo))-01-01"])
            out.append(["released", "<=", "\(max(yearFrom, yearTo))-12-31"])
        }
        if finishedOnly { out.append(["devstatus", "=", 0]) }
        for t in tags { out.append(["tag", "=", t.id]) }
        if let d = developer { out.append(["developer", "=", ["id", "=", d.id]]) }
        return out
    }

    /// Short labels for the active filters, each with a way to clear it.
    var chips: [(label: String, clear: (inout DiscoverFilters) -> Void)] {
        var out: [(String, (inout DiscoverFilters) -> Void)] = []
        if let d = developer { out.append(("By " + d.name, { $0.developer = nil })) }
        if !languages.isEmpty {
            let names = languages.sorted().map { l in Self.languageNames.first { $0.0 == l }?.1 ?? l }
            out.append(("In " + names.joined(separator: " or "), { $0.languages = [] }))
        }
        if let o = originalLanguage {
            out.append(("Originally " + (Self.languageNames.first { $0.0 == o }?.1 ?? o), { $0.originalLanguage = nil }))
        }
        if !platforms.isEmpty {
            out.append((platforms.sorted().map { p in Self.platformNames.first { $0.0 == p }?.1 ?? p }.joined(separator: ", "),
                        { $0.platforms = [] }))
        }
        if !lengths.isEmpty {
            out.append((lengths.sorted().map { l in String(Self.lengthNames.first { $0.0 == l }?.1.split(separator: " ").dropLast().joined(separator: " ") ?? "") }
                .joined(separator: ", "), { $0.lengths = [] }))
        }
        if let r = minRating { out.append(("★ \(r / 10)+", { $0.minRating = nil })) }
        switch released {
        case .any: break
        case .thisYear: out.append(("This year", { $0.released = .any }))
        case .last12Months: out.append(("Last 12 months", { $0.released = .any }))
        case .years: out.append((yearFrom == yearTo ? "\(yearFrom)" : "\(min(yearFrom, yearTo))–\(max(yearFrom, yearTo))", { $0.released = .any }))
        }
        if finishedOnly { out.append(("Finished only", { $0.finishedOnly = false })) }
        for t in tags { out.append((t.name, { f in f.tags.removeAll { $0 == t } })) }
        if hideInLibrary { out.append(("Not in library", { $0.hideInLibrary = false })) }
        return out
    }

    static func load() -> DiscoverFilters {
        guard let data = UserDefaults.standard.data(forKey: "discoverFilters"),
              let f = try? JSONDecoder().decode(DiscoverFilters.self, from: data) else { return DiscoverFilters() }
        return f
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "discoverFilters") }
    }
}

extension VNDB {
    private struct TagResponse: Decodable { struct T: Decodable { let id: String; let name: String; let vn_count: Int }; let results: [T] }

    private struct ProducerResponse: Decodable { struct P: Decodable { let id: String; let name: String; let original: String? }; let results: [P] }

    /// VNDB producers (developers and publishers) matching a search.
    static func searchProducers(_ q: String) async -> [DiscoverFilters.TagRef] {
        var req = URLRequest(url: URL(string: "https://api.vndb.org/kana/producer")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "filters": ["search", "=", q], "fields": "id,name,original", "results": 10,
        ])
        guard let data = try? await URLSession.shared.data(for: req).0,
              let r = try? JSONDecoder().decode(ProducerResponse.self, from: data) else { return [] }
        return r.results.map { p in DiscoverFilters.TagRef(id: p.id, name: p.original.map { "\(p.name) (\($0))" } ?? p.name) }
    }

    /// VNDB tags matching a search, most used first.
    static func searchTags(_ q: String) async -> [(DiscoverFilters.TagRef, Int)] {
        var req = URLRequest(url: URL(string: "https://api.vndb.org/kana/tag")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "filters": ["search", "=", q], "fields": "id,name,vn_count", "results": 12, "sort": "vn_count", "reverse": true,
        ])
        guard let data = try? await URLSession.shared.data(for: req).0,
              let r = try? JSONDecoder().decode(TagResponse.self, from: data) else { return [] }
        return r.results.map { (DiscoverFilters.TagRef(id: $0.id, name: $0.name), $0.vn_count) }
    }
}

/// The filter popover.
struct DiscoverFilterPanel: View {
    @Binding var filters: DiscoverFilters
    @State private var tagQuery = ""
    @State private var tagHits: [(DiscoverFilters.TagRef, Int)] = []
    @State private var devQuery = ""
    @State private var devHits: [DiscoverFilters.TagRef] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                group("Available in (release language)") {
                    WrapLayout(spacing: 6) {
                        ForEach(DiscoverFilters.languageNames, id: \.0) { code, name in
                            toggle(name, filters.languages.contains(code)) { filters.languages.formSymmetricDifference([code]) }
                        }
                    }
                }
                group("Original language") {
                    Picker("", selection: $filters.originalLanguage) {
                        Text("Any").tag(String?.none)
                        ForEach(DiscoverFilters.languageNames, id: \.0) { Text($0.1).tag(String?.some($0.0)) }
                    }
                    .labelsHidden().frame(width: 220)
                }
                group("Platform") {
                    WrapLayout(spacing: 6) {
                        ForEach(DiscoverFilters.platformNames, id: \.0) { code, name in
                            toggle(name, filters.platforms.contains(code)) { filters.platforms.formSymmetricDifference([code]) }
                        }
                    }
                }
                group("Length") {
                    WrapLayout(spacing: 6) {
                        ForEach(DiscoverFilters.lengthNames, id: \.0) { n, name in
                            toggle(name, filters.lengths.contains(n)) { filters.lengths.formSymmetricDifference([n]) }
                        }
                    }
                }
                HStack(alignment: .top, spacing: 30) {
                    group("Rating") {
                        Picker("", selection: $filters.minRating) {
                            Text("Any").tag(Int?.none)
                            ForEach([60, 70, 75, 80, 85], id: \.self) { Text("★ \(String(format: "%.1f", Double($0) / 10))+").tag(Int?.some($0)) }
                        }
                        .labelsHidden().frame(width: 120)
                    }
                    group("Development") {
                        Toggle("Finished only", isOn: $filters.finishedOnly)
                    }
                }
                group("Released") {
                    Picker("", selection: $filters.released) {
                        Text("Any time").tag(DiscoverFilters.Released.any)
                        Text("This year").tag(DiscoverFilters.Released.thisYear)
                        Text("Last 12 months").tag(DiscoverFilters.Released.last12Months)
                        Text("Between years…").tag(DiscoverFilters.Released.years)
                    }
                    .labelsHidden().frame(width: 220)
                    if filters.released == .years {
                        HStack {
                            Stepper("From \(String(filters.yearFrom))", value: $filters.yearFrom, in: 1980...2100)
                            Stepper("to \(String(filters.yearTo))", value: $filters.yearTo, in: 1980...2100)
                        }
                    }
                }
                group("Tags (all must match)") {
                    if !filters.tags.isEmpty {
                        WrapLayout(spacing: 6) {
                            ForEach(filters.tags, id: \.self) { t in
                                toggle(t.name + "  ✕", true) { filters.tags.removeAll { $0 == t } }
                            }
                        }
                    }
                    TextField("Search tags, e.g. Nakige, Kinetic Novel", text: $tagQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { tagHits = await VNDB.searchTags(tagQuery) } }
                        .task(id: tagQuery) {
                            try? await Task.sleep(for: .milliseconds(350))
                            guard !Task.isCancelled else { return }
                            tagHits = tagQuery.count < 2 ? [] : await VNDB.searchTags(tagQuery)
                        }
                    ForEach(tagHits, id: \.0) { tag, count in
                        Button {
                            if !filters.tags.contains(tag) { filters.tags.append(tag) }
                            tagQuery = ""
                            tagHits = []
                        } label: {
                            HStack { Text(tag.name); Spacer(); Text("\(count)").foregroundStyle(.secondary) }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                    }
                }
                group("Developer / publisher") {
                    if let d = filters.developer {
                        toggle(d.name + "  ✕", true) { filters.developer = nil }
                    }
                    TextField("Search companies, e.g. Key, Yuzusoft", text: $devQuery)
                        .textFieldStyle(.roundedBorder)
                        .task(id: devQuery) {
                            try? await Task.sleep(for: .milliseconds(350))
                            guard !Task.isCancelled else { return }
                            devHits = devQuery.count < 2 ? [] : await VNDB.searchProducers(devQuery)
                        }
                    ForEach(devHits, id: \.id) { p in
                        Button {
                            filters.developer = p
                            devQuery = ""
                            devHits = []
                        } label: {
                            Text(p.name).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                    }
                }
                group("Library") {
                    Toggle("Hide VNs already in my library", isOn: $filters.hideInLibrary)
                }
                HStack {
                    Button("Reset to Japanese only") { filters = DiscoverFilters() }
                    Button("Clear All") {
                        filters = DiscoverFilters()
                        filters.languages = []
                    }
                }
            }
            .padding(18)
        }
        .frame(width: 440, height: 600)
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            c()
        }
    }

    private func toggle(_ label: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .foregroundStyle(on ? Color.white : Color.primary)
                .background(Capsule().fill(on ? Color.kAccent : Color.kPanel2))
                .overlay(Capsule().strokeBorder(on ? Color.kAccent : Color.kLine))
        }
        .buttonStyle(.plain)
    }
}

extension Notification.Name {
    /// Posted with a TagRef (producer) to open Discover on that company.
    static let showDeveloper = Notification.Name("VNLibraryShowDeveloper")
}

extension Library {
    /// Opens Discover on everything a developer made, newest first. The id is
    /// looked up by name when the stored VNDB data predates producer ids.
    func showDeveloper(name: String, id: String?) {
        Task {
            var pid = id ?? ""
            if pid.isEmpty {
                pid = await VNDB.searchProducers(name).first { $0.name == name || $0.name.hasPrefix(name + " (") }?.id ?? ""
            }
            guard !pid.isEmpty else { alert = "Couldn't find \(name) on VNDB."; return }
            var f = DiscoverFilters.load()
            f.developer = DiscoverFilters.TagRef(id: pid, name: name)
            f.save()
            UserDefaults.standard.set(VNDB.BrowseSort.released.rawValue, forKey: "discoverSort")
            NotificationCenter.default.post(name: .showDeveloper, object: nil)
        }
    }
}

/// A developer name you can click to see all of their releases.
struct DeveloperLinks: View {
    @EnvironmentObject var lib: Library
    let names: [String]
    let ids: [String]?
    var after: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                Button {
                    lib.showDeveloper(name: name, id: ids.flatMap { $0.indices.contains(i) ? $0[i] : nil })
                    after()
                } label: {
                    Chip {
                        Image(systemName: "building.2").foregroundStyle(Color.kAccent)
                        Text(name).foregroundStyle(Color.kText).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .help("Show everything by \(name)")
            }
        }
    }
}
