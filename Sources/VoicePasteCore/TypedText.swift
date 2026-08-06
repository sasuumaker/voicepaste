import Foundation

/// クリップボードを使わずに文字を直接送り込むときの、送信単位の切り分け。
///
/// 一度のキーイベントに載せられる文字数には実質的な上限があるので刻んで送る。
/// このとき **書記素（見た目ひとつぶんの文字）の途中で切ってはいけない**。
/// 絵文字や結合文字はUTF-16で2つ以上に分かれるため、割ると文字化けする。
public enum TypedText {
    /// 1回のキーイベントに載せるUTF-16の長さの上限
    public static let defaultChunkLimit = 20

    /// UTF-16で `limit` を超えない範囲に分ける。書記素の途中では切らない。
    /// 1文字だけで `limit` を超える場合は、その文字を単独の塊として通す（割るよりは良い）
    public static func chunks(of text: String, limit: Int = defaultChunkLimit) -> [String] {
        guard limit > 0 else { return text.isEmpty ? [] : [text] }
        var chunks: [String] = []
        var current = ""
        var currentLength = 0

        for character in text {
            let length = String(character).utf16.count
            if currentLength > 0, currentLength + length > limit {
                chunks.append(current)
                current = ""
                currentLength = 0
            }
            current.append(character)
            currentLength += length
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
