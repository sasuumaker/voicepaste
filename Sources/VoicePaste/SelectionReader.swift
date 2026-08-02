import AppKit
import ApplicationServices
import Foundation

/// 前面アプリで選択中のテキストを取得する。
/// 第一選択はアクセシビリティAPI（クリップボードを汚さない）。
/// AXが使えないアプリ（Electron系など）では Cmd+C 送出にフォールバックし、
/// クリップボードは退避→復元する（プレーンテキストのみ）。
enum SelectionReader {
    static func read() -> String? {
        if let text = readViaAX(), !text.isEmpty { return text }
        guard AXIsProcessTrusted() else { return nil }
        return readViaCmdC()
    }

    private static func readViaAX() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String else { return nil }
        return text
    }

    private static func readViaCmdC() -> String? {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        let savedChangeCount = pasteboard.changeCount

        sendCmdC()

        // コピー反映（changeCountの増加）を最大0.5秒待つ
        let deadline = Date().addingTimeInterval(0.5)
        while pasteboard.changeCount == savedChangeCount, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard pasteboard.changeCount != savedChangeCount else { return nil }  // 選択なし

        let text = pasteboard.string(forType: .string)

        // 退避していた中身に戻す（選択テキストは呼び出し側が保持する）
        pasteboard.clearContents()
        if let saved { pasteboard.setString(saved, forType: .string) }

        guard let text, !text.isEmpty else { return nil }
        return text
    }

    /// Cmd+C も貼り付けと同じ問題を持つ。合成イベントのフラグは実際に押されているキーと
    /// 合わさるので、⌃/ を押したまま Cmd+C を送っても相手には ⌃⌘C として届いてコピーにならない。
    /// 短押し（トグル）ならすぐ指が離れるので少しだけ待つ。
    /// 押しっぱなし方式のときは離れないまま抜けるが、その場合も従来どおり送るので今より悪くはならない。
    /// なお第一選択のアクセシビリティAPI経路はキーを送らないのでこの問題と無関係。
    /// 押下判定は `NSEvent.modifierFlags`。`CGEventSource.flagsState` は指を離しても
    /// 「押されたまま」と報告し続けることがあり、待ち上限をまるごと使ってしまう（実測済み）
    private static func waitForModifierRelease(limit: TimeInterval = 0.3) {
        let deadline = Date().addingTimeInterval(limit)
        let blocking: NSEvent.ModifierFlags = [.control, .option, .shift]
        while !NSEvent.modifierFlags.intersection(blocking).isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    private static func sendCmdC() {
        waitForModifierRelease()
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true)  // c
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
