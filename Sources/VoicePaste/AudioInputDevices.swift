import CoreAudio
import Foundation
import VoicePasteCore

/// CoreAudioから「入力できる機器」の一覧を取る。
/// どれを使うかの判断は `InputDeviceSelection`（Core側・テスト済み）に任せ、ここは一覧を作るだけ
enum AudioInputDevices {
    struct Entry {
        let id: AudioDeviceID
        let info: InputDeviceInfo
    }

    /// 入力チャンネルを1つ以上持つ機器（マイク・仮想機器・iPhoneの連係マイクなど）
    static func list() -> [Entry] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let ids: [AudioDeviceID] = array(system, kAudioHardwarePropertyDevices) else { return [] }
        let systemDefault: AudioDeviceID = value(system, kAudioHardwarePropertyDefaultInputDevice) ?? 0

        return ids.compactMap { id in
            guard inputChannelCount(id) > 0 else { return nil }
            let name: String = (value(id, kAudioObjectPropertyName) as CFString?).map { $0 as String } ?? "名前不明"
            let uid: String = (value(id, kAudioDevicePropertyDeviceUID) as CFString?).map { $0 as String } ?? "id-\(id)"
            let transport: UInt32 = value(id, kAudioDevicePropertyTransportType) ?? 0
            return Entry(id: id, info: InputDeviceInfo(
                uid: uid,
                name: name,
                isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                isSystemDefault: id == systemDefault
            ))
        }
    }

    // MARK: - CoreAudio の読み出し

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func value<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buffer) == noErr else { return nil }
        return buffer.move()
    }

    private static func array<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [T]? {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<T>.size
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: max(count, 1))
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buffer) == noErr else { return nil }
        return Array(UnsafeBufferPointer(start: buffer, count: count))
    }

    private static func inputChannelCount(_ id: AudioObjectID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
