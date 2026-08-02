import Foundation

/// リアルタイム字幕で「次の発話に切り替わったか」を判定する。
///
/// 内蔵の音声認識は、少し黙っても認識タスクを終えないまま、
/// 結果の中身だけを次の発話用に作り直す。切り替わりを見つけて前の分を積まないと、
/// 黙るたびにそれまでの文章が消える。逆に検出しすぎると同じ文章を二重に積む。
///
/// 実測で分かった結果の並び（2026-08-02）:
/// ```
/// t=0.00 len=86   喋っている途中の部分結果。時刻はずっと 0
/// t=1.02 len=85   いま喋った分が「確定」したときだけ時刻が入る。中身は同じ文章
/// t=0.00 len=1    ここから次の発話。時刻が 0 に戻り、文字数も振り出しに戻る
/// ```
/// 切り替わりは**確定の次**に来る。確定そのものを切り替わりと読むと二重になる。
public enum UtteranceBoundary {
    public static func isNew(
        previousText: String,
        previousSegmentStart: TimeInterval,
        text: String,
        segmentStart: TimeInterval
    ) -> Bool {
        guard !previousText.isEmpty else { return false }
        // 確定（時刻あり）の次に時刻0が来たら、そこからが次の発話
        if previousSegmentStart > 0, segmentStart == 0 { return true }
        // 時刻が取れない場合の保険: 文字数が半分以下に急に縮んだら振り出しに戻ったとみなす。
        // かな→漢字の言い換えでも多少は縮むので、半分という粗い閾値で誤検知を避ける
        return text.count * 2 < previousText.count
    }
}
