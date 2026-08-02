import AppKit
import Foundation

enum Paster {
    /// 指が離れるのを待つ上限。普通の打鍵は0.1秒前後で離れるのでここでほぼ通る。
    /// 超えたら押されたままでも送る（無反応で終わらせない）
    private static let modifierWaitLimit: TimeInterval = 0.3
    /// 待ちの刻み。体感の遅さに直結するので細かく見る
    private static let pollInterval: TimeInterval = 0.005
    /// クリップボードへの書き込みが相手に見えるまでの最低限の猶予
    private static let clipboardSettle: TimeInterval = 0.03

    /// テキストをクリップボードに入れ、前面アプリに Cmd+V を送ってカーソル位置に挿入する。
    /// アクセシビリティ権限がない場合はクリップボードに入れるだけ（手動 Cmd+V で貼れる）。
    /// - Parameter onPasted: 実際に ⌘V を送った瞬間に呼ばれる。
    ///   「貼り付けました」の表示をここに合わせると、表示と実際の貼り付けがズレない
    /// - Returns: 自動貼り付けまでできたら true
    @discardableResult
    static func paste(_ text: String, source: String = "音声入力", onPasted: (() -> Void)? = nil) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard AXIsProcessTrusted() else {
            PasteDebugLog.write(source, lines: [
                "文字数: \(text.count)",
                "結果: 送信せず（アクセシビリティ権限なし）。クリップボードには入れた",
            ])
            return false
        }

        scheduleCmdV(source: source, characters: text.count, onPasted: onPasted)
        return true
    }

    /// Cmd+V を送る。要点は「送るときに ⌃⌥⇧ が押されていない状態にする」こと。
    ///
    /// 合成したキーイベントのフラグは、実際に押されているキーの状態と合わさって相手に届く。
    /// ⌃⌘V のようなホットキーから貼り付けを起こすと、指がまだ ⌃ を押している間に ⌘V を送っても
    /// 相手には **⌃⌘V** として届き、貼り付けにならない＝「押したのに貼り付かない」。
    ///
    /// 指が離れるのを最大0.3秒だけ待ってから送る。普通に押して離せば0.1秒前後で通るので体感は即時。
    ///
    /// 押下判定は `NSEvent.modifierFlags`。`CGEventSource.flagsState` は指を離しても1秒以上
    /// 「押されたまま」と報告し続けた実測があり、これを信じると待ち上限を毎回使い切る（2026-08-02）。
    ///
    /// 「修飾キーの解放イベントを送って打ち消す」案も試したが採用しない。
    /// ホットキーの押下中に解放イベントを差し込むと、Carbonのホットキーが
    /// 「離された→また押された」と解釈して連続発火しうるうえ、
    /// ユーザーが打鍵中のShift等まで巻き込む危険がある。
    private static func scheduleCmdV(source: String, characters: Int, onPasted: (() -> Void)?) {
        let startedAt = Date()
        let heldAtRequest = NSEvent.modifierFlags
        waitForModifierRelease(startedAt: startedAt) { waited in
            let settle = max(0, clipboardSettle - waited)
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                let heldAtSend = NSEvent.modifierFlags
                let cgAtSend = CGEventSource.flagsState(.combinedSessionState)
                sendCmdV()
                onPasted?()
                PasteDebugLog.write(source, lines: [
                    "文字数: \(characters)",
                    "押下中の修飾キー（要求時）: \(DebugLog.describe(heldAtRequest))",
                    "キー解放待ち: \(Int(waited * 1000))ms",
                    "押下中の修飾キー（送信時）: NSEvent=\(DebugLog.describe(heldAtSend)) / CGEventSource=\(DebugLog.describe(cgAtSend))",
                    blocking(in: heldAtSend).isEmpty
                        ? "結果: ⌘V を送信"
                        : "結果: ⌘V を送信（待ち上限。修飾キーが押されたまま＝貼り付かない可能性）",
                ])
            }
        }
    }

    /// ⌘ 以外の修飾キー。⌘ は押されたままでも ⌘V として届くので邪魔にならない
    private static func blocking(in flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.control, .option, .shift])
    }

    private static func waitForModifierRelease(startedAt: Date, then body: @escaping (TimeInterval) -> Void) {
        let waited = Date().timeIntervalSince(startedAt)
        if !blocking(in: NSEvent.modifierFlags).isEmpty, waited < modifierWaitLimit {
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
                waitForModifierRelease(startedAt: startedAt, then: body)
            }
            return
        }
        body(waited)
    }

    private static func sendCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)  // v
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
