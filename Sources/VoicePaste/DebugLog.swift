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
