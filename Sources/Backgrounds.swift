import AppKit
import CoreImage
import SwiftUI

/// Background themes for the main window. All stay dark and quiet so covers
/// and text keep reading well; panels draw on top as before.
enum BackgroundTheme: String, CaseIterable, Identifiable {
    case midnight, aurora, sakura, ocean, ember, forest, cover
    var id: String { rawValue }

    var label: String {
        switch self {
        case .midnight: return "Midnight"
        case .aurora: return "Aurora"
        case .sakura: return "Sakura"
        case .ocean: return "Ocean"
        case .ember: return "Ember"
        case .forest: return "Forest"
        case .cover: return "Last played"
        }
    }

    /// Base colour and two soft glows (top-leading, bottom-trailing).
    var palette: (base: Color, glow1: Color, glow2: Color) {
        switch self {
        case .midnight, .cover: return (.kBackground, .clear, .clear)
        case .aurora: return (Color(hex: 0x0D0E16), Color(hex: 0x6D28D9), Color(hex: 0x0EA5E9))
        case .sakura: return (Color(hex: 0x140D12), Color(hex: 0xDB2777), Color(hex: 0xF9A8D4))
        case .ocean:  return (Color(hex: 0x0A1018), Color(hex: 0x1D4ED8), Color(hex: 0x14B8A6))
        case .ember:  return (Color(hex: 0x130D0B), Color(hex: 0xEA580C), Color(hex: 0xB91C1C))
        case .forest: return (Color(hex: 0x0B110E), Color(hex: 0x15803D), Color(hex: 0x65A30D))
        }
    }
}

/// The window background for the chosen theme.
struct AppBackground: View {
    @EnvironmentObject var lib: Library

    var body: some View {
        let theme = lib.backgroundTheme
        let p = theme.palette
        ZStack {
            p.base
            if theme == .cover, let img = coverImage {
                Image(nsImage: img).resizable().scaledToFill()
                    .saturation(1.3)
                    .opacity(0.6)
                // Darken towards the bottom, where the grid is busiest.
                LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            } else if theme != .midnight {
                RadialGradient(colors: [p.glow1.opacity(0.36), .clear], center: .topLeading, startRadius: 0, endRadius: 900)
                RadialGradient(colors: [p.glow2.opacity(0.24), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 800)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// The most recently played game's cover, softly blurred. Adult or
    /// hand-blurred covers are skipped, and nothing shows in discreet mode.
    private var coverImage: NSImage? {
        guard !lib.discreet else { return nil }
        let game = lib.games
            .filter { $0.cover != nil && !$0.isAdult && !$0.isBlurred }
            .max { ($0.lastPlayed ?? $0.added) < ($1.lastPlayed ?? $1.added) }
        guard let game, let name = game.cover else { return nil }
        if let cached = Self.cache[name] { return cached }
        guard let src = lib.image(for: game), let out = Self.backdrop(from: src) else { return nil }
        Self.cache[name] = out
        return out
    }

    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]

    /// A small, heavily blurred copy: cheap to draw at window size.
    private static func backdrop(from image: NSImage) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        let scale = 320 / max(input.extent.width, input.extent.height)
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let blurred = CIFilter(name: "CIGaussianBlur", parameters: [
            kCIInputImageKey: small.clampedToExtent(), kCIInputRadiusKey: 18.0,
        ])?.outputImage?.cropped(to: small.extent),
              let out = CIContext().createCGImage(blurred, from: small.extent) else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
    }
}

/// Settings: a row of theme swatches.
struct BackgroundThemePicker: View {
    @EnvironmentObject var lib: Library

    var body: some View {
        HStack(spacing: 10) {
            ForEach(BackgroundTheme.allCases) { t in
                VStack(spacing: 5) {
                    swatch(t)
                        .frame(width: 54, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(lib.backgroundTheme == t ? Color.kAccent : Color.kLine, lineWidth: lib.backgroundTheme == t ? 2 : 1))
                    Text(t.label).font(.system(size: 10))
                        .foregroundStyle(lib.backgroundTheme == t ? Color.kText : Color.kMuted)
                }
                .contentShape(Rectangle())
                .onTapGesture { lib.backgroundTheme = t }
            }
        }
    }

    @ViewBuilder
    private func swatch(_ t: BackgroundTheme) -> some View {
        let p = t.palette
        if t == .cover {
            ZStack {
                Color.kPanel2
                Image(systemName: "photo").foregroundStyle(Color.kMuted)
            }
        } else {
            ZStack {
                p.base
                RadialGradient(colors: [p.glow1.opacity(0.6), .clear], center: .topLeading, startRadius: 0, endRadius: 50)
                RadialGradient(colors: [p.glow2.opacity(0.45), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 45)
            }
        }
    }
}
