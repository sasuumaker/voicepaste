import Foundation

/// 編集モードの診断ログ（~/.config/voicepaste/edit-debug.log）。
/// 実地で「変な結果になった」ときに、選択・指示・出力のどの段階が壊れたかを特定するためのもの。
/// 新しい記録を先頭に追記し、全体を約20KBに丸める。
enum EditDebugLog {
    static var url: URL { DebugLog.url("edit-debug.log") }

    static func write(selection: String, instruction: String, result: String?, error: String? = nil) {
        var lines = [
            "[\(DebugLog.timestamp())] 編集モード",
            "  選択(\(selection.count)字): \(DebugLog.oneLine(selection, max: 120))",
            "  指示: \(DebugLog.oneLine(instruction, max: 200))",
        ]
        if let result {
            lines.append("  結果(\(result.count)字): \(DebugLog.oneLine(result, max: 120))")
        }
        if let error {
            lines.append("  エラー: \(DebugLog.oneLine(error, max: 200))")
        }
        DebugLog.prepend(lines.joined(separator: "\n") + "\n", to: "edit-debug.log")
    }
}
