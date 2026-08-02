import Foundation

/// 文字列を自然に繋ぐ。日本語どうしは詰めて、英語のように空白で区切る言語だけ空白を入れる。
/// 整形が足した改行を畳むときと、リアルタイム字幕で確定済みの文と続きを繋ぐときの両方で使う。
public enum TextJoin {
    public static func concat(_ left: String, _ right: String) -> String {
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        guard let last = left.last, let next = right.first else { return left + right }
        if last.isWhitespace || next.isWhitespace { return left + right }
        return (isJapanese(last) || isJapanese(next)) ? left + right : left + " " + right
    }

    public static func isJapanese(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x303F,  // 句読点・記号
             0x3040...0x309F,  // ひらがな
             0x30A0...0x30FF,  // カタカナ
             0x4E00...0x9FFF,  // 漢字
             0xFF00...0xFFEF:  // 全角英数・全角記号
            return true
        default:
            return false
        }
    }
}
