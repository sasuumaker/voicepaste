import Foundation

/// "ctrl+cmd+v" のような文字列を Carbon のキーコード/修飾キーに変換する。
/// Core を Carbon 非依存に保つため、修飾キー定数は数値で持つ。
public struct HotKeySpec: Equatable {
    public let keyCode: UInt32
    public let carbonModifiers: UInt32

    // Carbon modifier constants
    public static let cmd: UInt32 = 0x100
    public static let shift: UInt32 = 0x200
    public static let option: UInt32 = 0x800
    public static let control: UInt32 = 0x1000

    static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
        "j": 38, "k": 40, "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26,
        "8": 28, "9": 25, "0": 29,
        "space": 49, "return": 36, "tab": 48, "escape": 53,
        "comma": 43, "period": 47, "slash": 44, "semicolon": 41,
        "quote": 39, "minus": 27, "equal": 24, "backtick": 50,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103,
        "f12": 111, "f13": 105,
    ]

    /// 設定画面での見た目用。ここに無いキーは大文字にして表示する
    static let keySymbols: [String: String] = [
        "space": "Space", "return": "↩", "tab": "⇥", "escape": "⎋",
        "comma": ",", "period": ".", "slash": "/", "semicolon": ";",
        "quote": "'", "minus": "-", "equal": "=", "backtick": "`",
    ]

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// 例: "ctrl+cmd+v", "option+space", "shift+cmd+f13"
    public static func parse(_ string: String) -> HotKeySpec? {
        let parts = string.lowercased().split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let keyName = parts.last, parts.count >= 1 else { return nil }
        guard let keyCode = keyCodes[keyName] else { return nil }

        var modifiers: UInt32 = 0
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command", "⌘": modifiers |= cmd
            case "ctrl", "control", "⌃": modifiers |= control
            case "opt", "option", "alt", "⌥": modifiers |= option
            case "shift", "⇧": modifiers |= shift
            default: return nil
            }
        }
        return HotKeySpec(keyCode: keyCode, carbonModifiers: modifiers)
    }

    // MARK: - 逆引き（設定画面でキー入力を受け取って設定文字列に戻す）

    /// キーコード → 設定ファイルで使うキー名。未対応キーは nil
    public static func keyName(forKeyCode keyCode: UInt32) -> String? {
        keyCodes.first { $0.value == keyCode }?.key
    }

    /// 設定ファイルに書く形式（"ctrl+cmd+v"）。修飾キーの順は ⌃⌥⇧⌘ に固定する
    public var configString: String? {
        guard let name = Self.keyName(forKeyCode: keyCode) else { return nil }
        var parts: [String] = []
        if carbonModifiers & Self.control != 0 { parts.append("ctrl") }
        if carbonModifiers & Self.option != 0 { parts.append("option") }
        if carbonModifiers & Self.shift != 0 { parts.append("shift") }
        if carbonModifiers & Self.cmd != 0 { parts.append("cmd") }
        parts.append(name)
        return parts.joined(separator: "+")
    }

    /// 画面表示用（"⌃⌘V"）。設定画面とメニューで使う
    public var symbolString: String {
        var out = ""
        if carbonModifiers & Self.control != 0 { out += "⌃" }
        if carbonModifiers & Self.option != 0 { out += "⌥" }
        if carbonModifiers & Self.shift != 0 { out += "⇧" }
        if carbonModifiers & Self.cmd != 0 { out += "⌘" }
        if let name = Self.keyName(forKeyCode: keyCode) {
            out += Self.keySymbols[name] ?? name.uppercased()
        } else {
            out += "?"
        }
        return out
    }

    /// "cmd+slash" → "⌘/"。解釈できない文字列はそのまま返す
    public static func symbolString(for string: String) -> String {
        parse(string)?.symbolString ?? string
    }

    /// 修飾キーなしのホットキーは通常のキー入力を丸ごと奪ってしまうので設定させない
    public var hasModifier: Bool {
        carbonModifiers & (Self.cmd | Self.shift | Self.option | Self.control) != 0
    }
}
