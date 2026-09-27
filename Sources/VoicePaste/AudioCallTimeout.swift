import Foundation

/// マイクの開始・停止が戻ってこないときの歯止め。
///
/// マイクの準備は CoreAudio の中で行われ、そこで止まるとメニューもホットキーも効かなくなり、
/// アプリは自分では戻れない（2026-09-27。AVAudioEngine の中で止まり、手で強制終了するまで固まっていた）。
/// 決めた秒数たっても終わらなければ、記録を残してアプリを終了する。
/// 自動起動（launchd の KeepAlive）は異常終了したアプリを起動し直すので、次のホットキーからまた使える。
/// 起動し直したあとは、理由をポップアップとメニューに出す（`takeRestartNote`）
final class AudioCallTimeout {
    /// 普段の開始は 0.03秒ほど。Bluetooth のマイクは切り替えに1〜2秒かかることがあるので余裕を見る
    static let limit: TimeInterval = 8

    private static var noteURL: URL { DebugLog.url("restarted-after-stall.txt") }

    private let item: DispatchWorkItem

    /// - Parameters:
    ///   - step: 何をしていたか（「録音の開始」など）。記録と再起動後の案内に使う
    ///   - mic: 使おうとしていたマイクの名前
    init(step: String, mic: String?, limit: TimeInterval = AudioCallTimeout.limit) {
        item = DispatchWorkItem {
            let seconds = Int(limit)
            TranscriptDebugLog.writeAudioProblem("★\(step)が\(seconds)秒たっても終わらないので、アプリを終了して起動し直した",
                                                 mic: mic)
            let note = "\(step)が\(seconds)秒止まったので、アプリを起動し直しました。もう一度ホットキーを押してください"
            try? note.write(to: AudioCallTimeout.noteURL, atomically: true, encoding: .utf8)
            // exit() は終了時の後片付けを実行する。主スレッドが CoreAudio の中で止まったままだと
            // 後片付けも同じところで待って終わらない恐れがあるので、後片付けなしで終える
            _exit(1)
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + limit, execute: item)
    }

    /// 間に合ったので取りやめる
    func cancel() {
        item.cancel()
    }

    /// 前回この歯止めで終了していたら、その案内を返して消す。起動時に1回呼ぶ
    static func takeRestartNote() -> String? {
        guard let note = try? String(contentsOf: noteURL, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: noteURL)
        return note
    }
}
