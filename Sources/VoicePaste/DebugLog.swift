import AppKit
import CoreGraphics
import Foundation

/// 診断ログの共通処理（~/.config/voicepaste/*.log）。
/// 新しい記録を先頭に足して、全体を上限で丸める。
enum DebugLog {
    static func url(_ filename: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/voicepaste/\(filename)")
    }

    static func prepend(_ entry: String, to filename: String, limit: Int = 20_000) {
        let target = url(filename)
        let old = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
        let combined = String((entry + old).prefix(limit))
        try? combined.write(to: target, atomically: true, encoding: .utf8)
    }

    static func oneLine(_ text: String, max: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: "⏎")
        return flat.count > max ? String(flat.prefix(max)) + "…" : flat
    }

    static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    /// いま押されている修飾キーを ⌃⌥⇧⌘ で表す
    static func describe(_ flags: CGEventFlags) -> String {
        var out = ""
        if flags.contains(.maskControl) { out += "⌃" }
        if flags.contains(.maskAlternate) { out += "⌥" }
        if flags.contains(.maskShift) { out += "⇧" }
        if flags.contains(.maskCommand) { out += "⌘" }
        return out.isEmpty ? "なし" : out
    }

    static func describe(_ flags: NSEvent.ModifierFlags) -> String {
        var out = ""
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option) { out += "⌥" }
        if flags.contains(.shift) { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        return out.isEmpty ? "なし" : out
    }
}

/// リアルタイム字幕の診断ログ（~/.config/voicepaste/caption-debug.log）。
/// 「喋っている途中で字幕が消える」が起きたとき、認識が何回・どんな理由で打ち切られ、
/// そのとき何文字ぶんを保持できていたかを見るためのもの。
enum CaptionDebugLog {
    static var url: URL { DebugLog.url("caption-debug.log") }

    /// 1回の録音ぶんの認識結果の推移。
    /// 「t=発話の開始位置 / len=そのときの文字数」が並ぶので、
    /// どこで発話が切り替わり、そこで文章を積めていたかを後から追える
    static func writeTrace(_ lines: [String], finalText: String) {
        let entry = """
            [\(DebugLog.timestamp())] 字幕の推移（\(lines.count)件）
              最終(\(finalText.count)字): \(DebugLog.oneLine(finalText, max: 200))
            \(lines.map { "  " + $0 }.joined(separator: "\n"))

            """
        DebugLog.prepend(entry, to: "caption-debug.log", limit: 30_000)
    }

    static func write(reason: String, kept: String, restartCount: Int) {
        let entry = """
            [\(DebugLog.timestamp())] 字幕タスク張り直し（\(restartCount)回目）
              理由: \(DebugLog.oneLine(reason, max: 120))
              保持(\(kept.count)字): \(DebugLog.oneLine(kept, max: 100))

            """
        DebugLog.prepend(entry, to: "caption-debug.log", limit: 10_000)
    }

    /// 部分結果が1件も来ないまま録音が終わった。
    /// 以前はこの場合に何も残らず、字幕が出ない原因（短すぎ／認識停止）を後から切り分けられなかった（2026-08-30）
    static func writeEmpty(seconds: TimeInterval, restartCount: Int) {
        let entry = String(format: "[%@] ★字幕なし（部分結果0件）録音 %.1f秒 / 張り直し %d回\n\n",
                           DebugLog.timestamp(), seconds, restartCount)
        DebugLog.prepend(entry, to: "caption-debug.log", limit: 30_000)
    }

    /// 字幕を始められなかった（権限なし・認識が利用不可・端末内で認識できない言語）
    static func writeUnavailable(reason: String) {
        let entry = "[\(DebugLog.timestamp())] ★字幕を開始できず: \(DebugLog.oneLine(reason, max: 120))\n\n"
        DebugLog.prepend(entry, to: "caption-debug.log", limit: 30_000)
    }
}

/// 認識と整形の診断ログ（~/.config/voicepaste/transcript-debug.log）。
///
/// 「変な文字が貼られた」ときに、聞き取りが外したのか整形が書き換えたのかを分けるためのもの。
/// これが無かったせいで2026-08-10の切り分けが大きく回り道した（文字数しか残っていなかった）。
enum TranscriptDebugLog {
    static var url: URL { DebugLog.url("transcript-debug.log") }

    /// - Parameters:
    ///   - candidate: 整形モデルが返してきた文。整形を通していないときは nil
    ///   - accepted: 検算を通ったか。nil は検算にかけていない（整形オフ／整形が失敗）
    ///   - note: 整形を通していないときの理由（「整形オフ」「★整形に失敗: …」など）。candidate があるときは使わない。
    ///     以前は理由を書かず「整形オフ、または失敗」の一文だったため、整形モデルの廃止（HTTP 404）に9日間気づけなかった（2026-08-29）
    static func write(raw: String, candidate: String?, accepted: Bool?, note: String? = nil) {
        var lines = ["  生(\(raw.count)字): \(DebugLog.oneLine(raw, max: 300))"]
        if let candidate {
            lines.append("  整形後(\(candidate.count)字): \(DebugLog.oneLine(candidate, max: 300))")
        } else {
            lines.append("  整形後: なし（\(DebugLog.oneLine(note ?? "整形を通していない", max: 300))）")
        }
        switch accepted {
        case true?: lines.append("  判定: 採用")
        case false?: lines.append("  判定: ★破棄（中身が書き換わっていたので生テキストを貼った）")
        case nil: lines.append("  判定: 検算なし（生テキストをそのまま貼った）")
        }
        let entry = (["[\(DebugLog.timestamp())] 音声入力"] + lines).joined(separator: "\n") + "\n"
        DebugLog.prepend(entry, to: "transcript-debug.log", limit: 30_000)
    }
}

/// 貼り付けの診断ログ（~/.config/voicepaste/paste-debug.log）。
/// 「押したのに貼り付かない」が起きたとき、ホットキーが発火したのか /
/// 権限があるのか / 修飾キーが押しっぱなしだったのか を切り分けるためのもの。
enum PasteDebugLog {
    static var url: URL { DebugLog.url("paste-debug.log") }

    static func write(_ kind: String, lines: [String]) {
        let entry = (["[\(DebugLog.timestamp())] \(kind)"] + lines.map { "  \($0)" })
            .joined(separator: "\n") + "\n"
        DebugLog.prepend(entry, to: "paste-debug.log")
    }
}
