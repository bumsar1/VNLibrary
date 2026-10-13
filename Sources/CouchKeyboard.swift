import SwiftUI

/// An on-screen keyboard driven by a d-pad: ABC, hiragana and katakana
/// (VNDB searches Japanese titles too).
struct CouchKeyboard {
    enum Mode { case abc, hiragana, katakana }
    enum Key: Hashable {
        case char(String), space, backspace, mode, search
        case dakuten, handakuten, small
    }

    var mode: Mode = .abc
    var row = 1
    var col = 0
    var text = ""

    private static let abc = ["1234567890", "QWERTYUIOP", "ASDFGHJKL'", "ZXCVBNM-.!"]
    private static let kana = ["あいうえおかきくけこ", "さしすせそたちつてと", "なにぬねのはひふへほ",
                               "まみむめもやゆよわを", "らりるれろん"]

    /// The grid for the current mode; the last row is the wide action keys.
    var rows: [[Key]] {
        var grid: [[Key]]
        switch mode {
        case .abc:
            grid = Self.abc.map { $0.map { .char(String($0)) } }
        case .hiragana, .katakana:
            grid = Self.kana.map { line in line.map { .char(mode == .katakana ? Self.katakana(String($0)) : String($0)) } }
            grid[grid.count - 1] += [.dakuten, .handakuten, .char("ー"), .small]
        }
        grid.append([.mode, .space, .backspace, .search])
        return grid
    }

    mutating func move(dx: Int, dy: Int) -> Bool {
        let g = rows
        let r = row + dy
        guard r >= 0, r < g.count else { return false }
        // Moving between a 10-key row and the 4 action keys keeps roughly the same spot.
        if dy != 0 { col = Int((Double(col) + 0.5) / Double(g[row].count) * Double(g[r].count)) }
        let c = col + dx
        guard c >= 0, c < g[r].count else { return false }
        row = r
        col = min(c, g[r].count - 1)
        return true
    }

    /// Presses the focused key. Returns true when it was Search.
    mutating func press() -> Bool {
        let g = rows
        guard g.indices.contains(row), g[row].indices.contains(col) else { return false }
        return press(g[row][col])
    }

    mutating func press(_ key: Key) -> Bool {
        switch key {
        case .char(let c): text += c
        case .space: text += " "
        case .backspace: if !text.isEmpty { text.removeLast() }
        case .mode:
            mode = mode == .abc ? .hiragana : mode == .hiragana ? .katakana : .abc
            col = min(col, rows[row].count - 1)
        case .search: return true
        case .dakuten: modifyLast(by: Set("かきくけこさしすせそたちつてとはひふへほカキクケコサシスセソタチツテトハヒフヘホ"), offset: 1)
        case .handakuten: modifyLast(by: Set("はひふへほハヒフヘホ"), offset: 2)
        case .small: modifyLast(by: Set("あいうえおつやゆよわアイウエオツヤユヨワ"), offset: -1)
        }
        return false
    }

    /// か → が, は → ぱ, つ → っ: the voiced/small forms sit next to the plain
    /// ones in Unicode.
    private mutating func modifyLast(by allowed: Set<Character>, offset: Int) {
        guard let last = text.last, allowed.contains(last),
              let scalar = last.unicodeScalars.first,
              let changed = Unicode.Scalar(UInt32(Int(scalar.value) + offset)) else { return }
        text.removeLast()
        text.append(Character(changed))
    }

    static func katakana(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { u in
            (0x3041...0x3096).contains(u.value) ? Unicode.Scalar(u.value + 0x60)! : u
        }))
    }

    static func label(_ k: Key, mode: Mode) -> String {
        switch k {
        case .char(let c): return c
        case .space: return "Space"
        case .backspace: return "⌫"
        case .mode: return mode == .abc ? "あ" : mode == .hiragana ? "ア" : "ABC"
        case .search: return "Search"
        case .dakuten: return "゛"
        case .handakuten: return "゜"
        case .small: return "小"
        }
    }
}

struct CouchKeyboardView: View {
    let keyboard: CouchKeyboard
    let tap: (Int, Int) -> Void

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Image(systemName: "magnifyingglass").font(.system(size: 22))
                Text(keyboard.text.isEmpty ? "Search your library and VNDB" : keyboard.text + "▏")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white.opacity(keyboard.text.isEmpty ? 0.45 : 1))
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.1)))

            VStack(spacing: 8) {
                ForEach(Array(keyboard.rows.enumerated()), id: \.offset) { r, keys in
                    HStack(spacing: 8) {
                        ForEach(Array(keys.enumerated()), id: \.offset) { c, key in
                            let focused = r == keyboard.row && c == keyboard.col
                            let wide = r == keyboard.rows.count - 1
                            Text(CouchKeyboard.label(key, mode: keyboard.mode))
                                .font(.system(size: wide ? 17 : 21, weight: .semibold))
                                .foregroundStyle(focused ? .black : .white)
                                .frame(width: wide ? 150 : 56, height: 52)
                                .background(RoundedRectangle(cornerRadius: 10)
                                    .fill(focused ? Color.white : Color.white.opacity(key == .search ? 0.25 : 0.1)))
                                .scaleEffect(focused ? 1.08 : 1)
                                .animation(.easeOut(duration: 0.1), value: focused)
                                .onTapGesture { tap(r, c) }
                        }
                    }
                }
            }
            Text("Ⓐ type    Ⓑ delete / close    Ⓨ switch ABC · あ · ア    ☰ search    — or just type")
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
        }
        .padding(30)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color.black.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.white.opacity(0.12)))
        .frame(maxWidth: 760)
    }
}
