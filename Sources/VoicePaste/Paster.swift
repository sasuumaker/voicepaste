import AppKit
import Foundation
import VoicePasteCore

enum Paster {
    /// 指が離れるのを待つ上限。普通の打鍵は0.1秒前後で離れるのでここでほぼ通る。
    /// 超えたら押されたままでも送る（無反応で終わらせない）
    private static let modifierWaitLimit: TimeInterval = 0.3
    /// 待ちの刻み。体感の遅さに直結するので細かく見る
    private static let pollInterval: TimeInterval = 0.005
    /// クリップボードへの書き込みが相手に見えるまでの最低限の猶予
    private static let clipboardSettle: TimeInterval = 0.03
    /// 直接入力で塊と塊のあいだに空ける時間。詰めて送りすぎると取りこぼすアプリがある
    private static let typingInterval: TimeInterval = 0.002

    /// 直接入力はイベントを順番に送るので、重ならないよう1本の列で流す
    private static let typingQueue = DispatchQueue(label: "com.sasuu.voicepaste.typing")

    /// テキストを前面アプリのカーソル位置に挿入する。
    ///
    /// 既定では**クリップボードを使わず**、文字そのものをキー入力として送り込む。
    /// クリップボード経由だと、貼り付けるたびに履歴アプリ（Clipy等）へ音声入力の結果が積まれてしまうため。
    /// `viaClipboard` が true のときだけ、従来どおりクリップボードに入れて ⌘V を送る。
    ///
    /// アクセシビリティ権限がない場合はどちらの方法も使えないので、
    /// 最後の手段としてクリップボードに入れるだけにする（手動 ⌘V で貼れる）。
    ///
    /// - Parameter onPasted: 実際に送り終えた瞬間に呼ばれる。
    ///   「貼り付けました」の表示をここに合わせると、表示と実際の貼り付けがズレない
    /// - Returns: 自動で挿入までできたら true
    @discardableResult
    static func paste(
        _ text: String,
        source: String = "音声入力",
        viaClipboard: Bool = false,
        onPasted: (() -> Void)? = nil
    ) -> Bool {
        guard AXIsProcessTrusted() else {
            copyToClipboard(text)
            PasteDebugLog.write(source, lines: [
                "文字数: \(text.count)",
                "結果: 送信せず（アクセシビリティ権限なし）。クリップボードには入れた",
            ])
            return false
        }

        if viaClipboard {
            copyToClipboard(text)
        }
        scheduleDelivery(source: source, text: text, viaClipboard: viaClipboard, onPasted: onPasted)
        return true
    }

    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// 送るときに、邪魔になる修飾キーが押されていない状態にしてから送る。
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
    private static func scheduleDelivery(
        source: String,
        text: String,
        viaClipboard: Bool,
        onPasted: (() -> Void)?
    ) {
        let startedAt = Date()
        let heldAtRequest = NSEvent.modifierFlags
        waitForModifierRelease(startedAt: startedAt, viaClipboard: viaClipboard) { waited in
            let settle = viaClipboard ? max(0, clipboardSettle - waited) : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                let heldAtSend = NSEvent.modifierFlags
                let cgAtSend = CGEventSource.flagsState(.combinedSessionState)
                let stuck = !blocking(in: heldAtSend, viaClipboard: viaClipboard).isEmpty

                func log(_ result: String) {
                    PasteDebugLog.write(source, lines: [
                        "文字数: \(text.count)",
                        "方式: \(viaClipboard ? "クリップボード＋⌘V" : "直接入力（クリップボードを使わない）")",
                        "押下中の修飾キー（要求時）: \(DebugLog.describe(heldAtRequest))",
                        "キー解放待ち: \(Int(waited * 1000))ms",
                        "押下中の修飾キー（送信時）: NSEvent=\(DebugLog.describe(heldAtSend)) / CGEventSource=\(DebugLog.describe(cgAtSend))",
                        stuck ? "\(result)（待ち上限。修飾キーが押されたまま＝正しく入らない可能性）" : result,
                    ])
                }

                if viaClipboard {
                    sendCmdV()
                    onPasted?()
                    log("結果: ⌘V を送信")
                } else {
                    let chunks = TypedText.chunks(of: text)
                    typeText(chunks) { onPasted?() }
                    log("結果: 文字を直接送信（\(chunks.count)回に分割）")
                }
            }
        }
    }

    /// 送信を邪魔する修飾キー。
    /// クリップボード方式では ⌘ は押されたままでも ⌘V として届くので邪魔にならないが、
    /// 直接入力では ⌘ が押されたままだと一文字ずつがショートカットとして解釈されてしまうので待つ
    private static func blocking(in flags: NSEvent.ModifierFlags, viaClipboard: Bool) -> NSEvent.ModifierFlags {
        let unwanted: NSEvent.ModifierFlags = viaClipboard ? [.control, .option, .shift] : [.control, .option, .shift, .command]
        return flags.intersection(unwanted)
    }

    private static func waitForModifierRelease(
        startedAt: Date,
        viaClipboard: Bool,
        then body: @escaping (TimeInterval) -> Void
    ) {
        let waited = Date().timeIntervalSince(startedAt)
        if !blocking(in: NSEvent.modifierFlags, viaClipboard: viaClipboard).isEmpty, waited < modifierWaitLimit {
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
                waitForModifierRelease(startedAt: startedAt, viaClipboard: viaClipboard, then: body)
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

    /// 文字そのものをキーイベントに載せて送る。クリップボードには一切触れない。
    ///
    /// キーコードは0固定で、実際に入る文字は `keyboardSetUnicodeString` で差し替える。
    /// 修飾キーのフラグは必ず空にする（残っているとショートカットとして解釈される）。
    private static func typeText(_ chunks: [String], completion: @escaping () -> Void) {
        typingQueue.async {
            let source = CGEventSource(stateID: .combinedSessionState)
            for chunk in chunks {
                var utf16 = Array(chunk.utf16)
                guard
                    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
                else { continue }
                keyDown.flags = []
                keyUp.flags = []
                keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                keyDown.post(tap: .cghidEventTap)
                keyUp.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: typingInterval)
            }
            DispatchQueue.main.async(execute: completion)
        }
    }
}
