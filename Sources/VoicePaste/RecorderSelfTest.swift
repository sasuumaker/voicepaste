import Foundation
import VoicePasteCore

/// 録音の開始・停止をくり返して、マイクが毎回開けて音が届くかを確かめる（`VoicePaste --selftest-record 回数`）。
///
/// 2026-09-27 の「録音開始でアプリが固まる」を直したときに、実機で確かめるために作った。
/// マイクの許可はアプリごとに付くので、`open` 経由で起動する（ターミナルから直接実行すると、
/// 許可を持たないターミナル側の扱いになり、音が0のまま届く）:
///
///     open -n -W --stdout out.txt --stderr out.txt build/VoicePaste.app --args --selftest-record 50
///
/// 2つ目の数は1回の録音の秒数（既定 0.5）。3つ目にパスを渡すと、最後の録音を WAV で保存する
/// （変換後の音が聞き取れるかを、Groq で文字起こしして確かめるため）
enum RecorderSelfTest {
    /// - Returns: 終了コード。すべて録れたら 0
    static func run(cycles: Int, seconds: TimeInterval = 0.5, saveLastTo wavPath: String? = nil) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)  // 途中で止まっても、そこまでの行がファイルに残るように
        let config = Config.load()
        let recorder = AudioRecorder()  // アプリと同じく1つを使い回す
        var failures = 0

        for index in 1...max(cycles, 1) {
            // アプリと同じく、毎回機器一覧を取り直してマイクを決める
            let devices = AudioInputDevices.list()
            let mic = InputDeviceSelection.resolve(setting: config.input_device, devices: devices.map(\.info))
            let deviceID = devices.first { $0.info.uid == mic.device?.uid }?.id
            let micName = mic.device?.name ?? "macOSの既定"

            let began = CFAbsoluteTimeGetCurrent()
            var liveAt: CFAbsoluteTime?
            do {
                try recorder.start(deviceID: deviceID, onCaptureLive: { liveAt = CFAbsoluteTimeGetCurrent() })
            } catch {
                failures += 1
                print("[\(index)] ★開始できず（\(micName)）: \(error.localizedDescription)")
                continue
            }
            let startTook = CFAbsoluteTimeGetCurrent() - began
            // 最初の音が届いた合図はメインスレッドに来るので、待つ間はメインの処理を回す
            RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
            let recorded = recorder.recordedSeconds
            let wav = recorder.stop()
            if index == cycles, let wavPath {
                try? wav.write(to: URL(fileURLWithPath: wavPath))
            }

            let firstSound = liveAt.map { String(format: "%.3f秒", $0 - began) } ?? "届かず"
            let ok = liveAt != nil && recorded >= seconds * 0.5
            if !ok { failures += 1 }
            print(String(format: "[%d] %@ 開始 %.3f秒／最初の音まで %@／録れた長さ %.2f秒／音量ピーク %.3f（%@）",
                         index, ok ? "OK" : "★NG", startTook, firstSound, recorded, recorder.lastPeak, micName))
        }

        print(failures == 0 ? "✅ \(cycles)回すべて録音できました" : "❌ \(cycles)回中 \(failures)回で失敗しました")
        return failures == 0 ? 0 : 1
    }
}
