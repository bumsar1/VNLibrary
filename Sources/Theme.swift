import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
    static let kBackground = Color(hex: 0x0F0F11)
    static let kPanel      = Color(hex: 0x161618)
    static let kPanel2     = Color(hex: 0x1D1D21)
    static let kLine       = Color(hex: 0x2A2A30)
    static let kText       = Color(hex: 0xECECF1)
    static let kMuted      = Color(hex: 0x8B8B96)
    static let kAccent     = Color(hex: 0x8B5CF6)
    static let kDone       = Color(hex: 0x4ADE80)
    static let kHinomaru   = Color(hex: 0xEF4444)
    static let kFlame      = Color(hex: 0xFB923C)
}

struct Chip<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 6) { content }
            .font(.system(size: 12))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.kPanel2))
            .overlay(Capsule().strokeBorder(Color.kLine))
    }
}
