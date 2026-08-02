import Carbon
import Foundation
import VoicePasteCore

/// Carbon RegisterEventHotKey ベースのグローバルホットキー。
/// アクセシビリティ権限なしで動くのが利点（貼り付け側は別途権限が必要）。
/// 押下(Pressed)と解放(Released)の両方を扱い、キーリピートによる連打誤発火は抑止する。
final class HotKeyManager {
    private var pressHandlers: [UInt32: () -> Void] = [:]
    private var releaseHandlers: [UInt32: () -> Void] = [:]
    private var isDown: Set<UInt32> = []
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1

    init() {
        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.handle(id: hotKeyID.id, kind: GetEventKind(event))
                return noErr
            },
            2,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    private func handle(id: UInt32, kind: UInt32) {
        switch kind {
        case UInt32(kEventHotKeyPressed):
            // 押しっぱなしのキーリピートで再発火しない（Released が来るまで1回だけ）
            guard !isDown.contains(id) else { return }
            isDown.insert(id)
            pressHandlers[id]?()
        case UInt32(kEventHotKeyReleased):
            isDown.remove(id)
            releaseHandlers[id]?()
        default:
            break
        }
    }

    @discardableResult
    func register(_ spec: HotKeySpec, onRelease: (() -> Void)? = nil, handler: @escaping () -> Void) -> Bool {
        let id = nextID
        nextID += 1
        pressHandlers[id] = handler
        if let onRelease { releaseHandlers[id] = onRelease }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5650_4153), id: id)  // 'VPAS'
        let status = RegisterEventHotKey(
            spec.keyCode,
            spec.carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        hotKeyRefs.append(ref)
        return status == noErr
    }

    /// 登録済みのホットキーを全部外す。設定画面でキーを変えたときに
    /// アプリを再起動せずに再登録するために使う
    func unregisterAll() {
        for ref in hotKeyRefs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        hotKeyRefs.removeAll()
        pressHandlers.removeAll()
        releaseHandlers.removeAll()
        isDown.removeAll()
    }
}
