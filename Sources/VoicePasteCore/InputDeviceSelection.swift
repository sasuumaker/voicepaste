import Foundation

/// 録音に使えるマイク1件（CoreAudioから取った一覧の要素。UIなしでテストできるようにここに置く）
public struct InputDeviceInfo: Equatable {
    /// 機器を一意に指す文字列。設定ファイルにはこれを保存する（名前は変わりうる）
    public let uid: String
    public let name: String
    /// Mac本体の内蔵マイクか
    public let isBuiltIn: Bool
    /// macOSの「サウンド」設定でいま入力に選ばれている機器か
    public let isSystemDefault: Bool

    public init(uid: String, name: String, isBuiltIn: Bool, isSystemDefault: Bool) {
        self.uid = uid
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.isSystemDefault = isSystemDefault
    }
}

/// 設定値 `input_device` と、いまつながっている機器の一覧から、録音に使うマイクを決める。
///
/// AirPodsをつなぐとmacOSの既定入力がAirPodsに切り替わり、認識の精度が大きく落ちる（本人の実感・2026-08-30）。
/// そのため既定は「Macの内蔵マイク」で、macOSの既定には従わない。従いたいときは `"system"` にする
public enum InputDeviceSelection {
    /// 設定値: Macの内蔵マイクを使う（既定）
    public static let builtIn = "builtin"
    /// 設定値: macOSの「サウンド」設定の入力に従う（AirPodsをつなげばAirPods）
    public static let followSystem = "system"

    public struct Resolution: Equatable {
        /// 使うマイク。nil は「macOSの既定の入力を使う」
        public let device: InputDeviceInfo?
        /// 設定どおりに選べなかったときの理由。設定どおりなら nil
        public let note: String?

        public init(device: InputDeviceInfo?, note: String?) {
            self.device = device
            self.note = note
        }
    }

    /// - Parameters:
    ///   - setting: `Config.input_device`。`builtin` / `system` / 機器のUID。空は `builtin` と同じ
    ///   - devices: いまつながっている入力機器
    public static func resolve(setting: String, devices: [InputDeviceInfo]) -> Resolution {
        let builtInDevice = devices.first { $0.isBuiltIn }
        let systemDevice = devices.first { $0.isSystemDefault }
        let systemName = systemDevice?.name ?? "不明"

        switch setting {
        case followSystem:
            return Resolution(device: systemDevice, note: nil)
        case builtIn, "":
            if let builtInDevice { return Resolution(device: builtInDevice, note: nil) }
            return Resolution(device: systemDevice,
                              note: "内蔵マイクが見つからないので、macOSの既定の入力（\(systemName)）を使います")
        default:
            if let chosen = devices.first(where: { $0.uid == setting }) {
                return Resolution(device: chosen, note: nil)
            }
            if let builtInDevice {
                return Resolution(device: builtInDevice,
                                  note: "設定したマイクが見つからないので、内蔵マイク（\(builtInDevice.name)）を使います")
            }
            return Resolution(device: systemDevice,
                              note: "設定したマイクも内蔵マイクも見つからないので、macOSの既定の入力（\(systemName)）を使います")
        }
    }
}
