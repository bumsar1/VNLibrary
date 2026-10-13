import SwiftUI

/// Screenshots and package scans for a VN, from VNDB.
struct GalleryImage: Identifiable, Hashable {
    let url: String
    let thumbnail: String
    let sexual: Double
    let kind: String          // "Screenshot", "Front cover", …
    var id: String { url }
}

extension VNDB {
    private struct Img: Decodable { let url: String; let thumbnail: String?; let sexual: Double?; let type: String? }
    private struct ShotResponse: Decodable { struct VN: Decodable { let screenshots: [Img]? }; let results: [VN] }
    private struct ReleaseResponse: Decodable { struct R: Decodable { let images: [Img]? }; let results: [R] }

    private static func kindLabel(_ type: String?) -> String {
        switch type {
        case "pkgfront": return "Front cover"
        case "pkgback": return "Back cover"
        case "pkgcontent": return "Package contents"
        case "pkgside": return "Package side"
        case "pkgmed": return "Disc / media"
        case "dig": return "Digital cover"
        default: return "Release image"
        }
    }

    /// Release covers first (most useful as cover art), then screenshots.
    static func gallery(for vid: String) async throws -> [GalleryImage] {
        async let shots: Data = rawPost("vn", ["filters": ["id", "=", vid], "fields": "screenshots.url,screenshots.thumbnail,screenshots.sexual", "results": 1])
        async let releases: Data = rawPost("release", ["filters": ["vn", "=", ["id", "=", vid]],
                                                       "fields": "images.url,images.thumbnail,images.sexual,images.type", "results": 100])
        let dec = JSONDecoder()
        let s = try dec.decode(ShotResponse.self, from: try await shots).results.first?.screenshots ?? []
        let r = try dec.decode(ReleaseResponse.self, from: try await releases).results.flatMap { $0.images ?? [] }
        var seen = Set<String>()
        let covers = r.sorted { ($0.type == "pkgfront" || $0.type == "dig" ? 0 : 1) < ($1.type == "pkgfront" || $1.type == "dig" ? 0 : 1) }
            .map { GalleryImage(url: $0.url, thumbnail: $0.thumbnail ?? $0.url, sexual: $0.sexual ?? 0, kind: kindLabel($0.type)) }
        let screens = s.map { GalleryImage(url: $0.url, thumbnail: $0.thumbnail ?? $0.url, sexual: $0.sexual ?? 0, kind: "Screenshot") }
        return (covers + screens).filter { seen.insert($0.url).inserted }
    }

    private static func rawPost(_ endpoint: String, _ payload: [String: Any]) async throws -> Data {
        var req = URLRequest(url: URL(string: "https://api.vndb.org/kana/\(endpoint)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return try await URLSession.shared.data(for: req).0
    }
}

extension Library {
    /// Whether a VNDB image should be blurred: always in discreet mode,
    /// otherwise when VNDB flags it as suggestive, unless the user revealed it.
    func shouldBlur(sexual: Double, key: String) -> Bool {
        if discreet { return true }
        if unblurAll { return false }
        return blurSuggestive && sexual >= 1 && !revealed.contains(key)
    }

    /// Downloads an image from VNDB and makes it the game's cover.
    func setCover(_ id: UUID, fromRemote url: String) async {
        guard let data = try? await VNDB.download(url), NSImage(data: data) != nil else {
            alert = "Couldn't download that image."
            return
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try? data.write(to: tmp)
        setCover(id, from: tmp)
        try? FileManager.default.removeItem(at: tmp)
    }
}

/// A row of thumbnails; click one to see it large.
struct GalleryStrip: View {
    @EnvironmentObject var lib: Library
    let vid: String
    @Binding var viewing: Int?
    @Binding var images: [GalleryImage]
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(images.isEmpty ? "IMAGES" : "IMAGES · \(images.count)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.kMuted)
            if loading {
                ProgressView().controlSize(.small)
            } else if images.isEmpty {
                Text("No screenshots or package images on VNDB.")
                    .font(.system(size: 12)).foregroundStyle(Color.kMuted)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 8) {
                        ForEach(Array(images.enumerated()), id: \.element.id) { i, img in
                            RemoteImage(url: img.thumbnail, blurred: lib.shouldBlur(sexual: img.sexual, key: img.url))
                                .frame(width: img.kind == "Screenshot" ? 136 : 64, height: 84)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.kLine))
                                .help(img.kind)
                                .onTapGesture { viewing = i }
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
        }
        .task(id: vid) {
            loading = true
            images = (try? await VNDB.gallery(for: vid)) ?? []
            loading = false
        }
    }
}

/// Large view of one gallery image, with arrows to step through the rest.
struct GalleryViewer: View {
    @EnvironmentObject var lib: Library
    let images: [GalleryImage]
    @Binding var index: Int?
    /// When set, offers "Use as Cover" for this library game.
    var gameID: UUID?

    var body: some View {
        if let i = index, images.indices.contains(i) {
            let img = images[i]
            let blurred = lib.shouldBlur(sexual: img.sexual, key: img.url)
            ZStack {
                Color.black.opacity(0.97)
                    .onTapGesture { index = nil }
                VStack(spacing: 12) {
                    RemoteImage(url: img.url, blurred: blurred, fit: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack(spacing: 12) {
                        Button { step(-1) } label: { Image(systemName: "chevron.left") }
                            .keyboardShortcut(.leftArrow, modifiers: [])
                        Text("\(img.kind) · \(i + 1) of \(images.count)")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
                        Button { step(1) } label: { Image(systemName: "chevron.right") }
                            .keyboardShortcut(.rightArrow, modifiers: [])
                        Spacer()
                        if blurred && !lib.discreet {
                            Button("Show Image") { lib.revealed.insert(img.url) }
                        } else if lib.revealed.contains(img.url) && !lib.discreet {
                            Button("Blur Again") { lib.revealed.remove(img.url) }
                        }
                        if let gameID {
                            Button("Use as Cover") {
                                Task { await lib.setCover(gameID, fromRemote: img.url) }
                            }
                        }
                        Button("Done") { index = nil }
                            .keyboardShortcut(.cancelAction)
                    }
                }
                .padding(18)
            }
        }
    }

    private func step(_ d: Int) {
        guard let i = index, !images.isEmpty else { return }
        index = (i + d + images.count) % images.count
    }
}

/// An image from a URL, optionally blurred (CoreImage-free: the blur is on
/// the view, which is enough for images that never touch the library).
struct RemoteImage: View {
    let url: String
    var blurred = false
    var fit = false

    var body: some View {
        AsyncImage(url: URL(string: url)) { phase in
            if let image = phase.image {
                let base = image.resizable()
                Group {
                    if fit { base.scaledToFit() } else { base.scaledToFill() }
                }
                .blur(radius: blurred ? 24 : 0, opaque: !fit)
                .overlay {
                    if blurred {
                        Image(systemName: "eye.slash").font(.system(size: fit ? 30 : 16))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            } else if phase.error != nil {
                Image(systemName: "photo").foregroundStyle(Color.kMuted)
            } else {
                Color.kPanel2.overlay(ProgressView().controlSize(.small))
            }
        }
        .clipped()
    }
}
