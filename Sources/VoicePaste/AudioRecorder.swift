import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import VoicePasteCore

/// AVAudioEngine でマイク入力を取り、16kHz モノラル Float32 に変換して溜める
final class AudioRecorder {
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var onCaptureLive: (() -> Void)?
    private var captureLiveFired = false
    private var lastLevelSentAt: CFAbsoluteTime = 0
    private let lock = NSLock()
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    /// 入力レベル（0.0〜1.0）。画面下のポップアップのメーター用。メインスレッドで約20回/秒
    var onLevel: ((Float) -> Void)?
    /// 変換済み16kHzモノラルバッファ。リアルタイム字幕に横流しする。オーディオスレッドから呼ばれる
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    enum RecorderError: LocalizedError {
        case noInput
        case deviceNotSelectable(OSStatus)
        var errorDescription: String? {
            switch self {
            case .noInput: return "マイク入力を取得できません（マイク権限を確認してください）"
            case .deviceNotSelectable(let status): return "選んだマイクを録音に使えません（CoreAudio \(status)）。設定でマイクを変えてください"
            }
        }
    }

    /// 直近の録音の音量ピーク（0〜1）。「マイクが音を拾えていたか」を診断ログで確かめるため。
    /// 0.00 なら無音（選んだマイクが音を拾っていない／ミュート）
    private(set) var lastPeak: Float = 0

    var recordedSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(samples.count) / 16000.0
    }

    /// - Parameters:
    ///   - deviceID: 録音に使うマイク。nil なら macOS の既定入力に任せる
    ///   - onCaptureLive: 最初の音声バッファが届いた（＝実際に録音が生きた）タイミングで
    ///     メインスレッドから1回だけ呼ばれる。開始音はここで鳴らすことで喋り出しの欠けを防ぐ
    func start(deviceID: AudioDeviceID?, onCaptureLive: @escaping () -> Void) throws {
        lock.lock()
        samples.removeAll()
        lock.unlock()
        self.onCaptureLive = onCaptureLive
        self.captureLiveFired = false
        self.lastLevelSentAt = 0

        let engine = AVAudioEngine()
        let input = engine.inputNode
        // マイクは入力ノードの音声ユニットに直接指定する（AVAudioEngine はそのままだと macOS の既定入力を使う）。
        // 形式（サンプルレート等）は機器ごとに違うので、指定してから読む
        if let deviceID, let unit = input.audioUnit {
            var id = deviceID
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else { throw RecorderError.deviceNotSelectable(status) }
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInput
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecorderError.noInput
        }
        self.converter = converter

        let ratio = 16000.0 / inputFormat.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }
            if !self.captureLiveFired {
                self.captureLiveFired = true
                let callback = self.onCaptureLive
                DispatchQueue.main.async { callback?() }
            }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
            guard let output = AVAudioPCMBuffer(pcmFormat: self.targetFormat, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard error == nil, let channel = output.floatChannelData?[0] else { return }
            let converted = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            self.lock.lock()
            self.samples.append(contentsOf: converted)
            self.lock.unlock()

            // 変換済みバッファは毎回この場で作った自前のものなので、そのまま渡して安全
            self.onBuffer?(output)
            self.emitLevel(from: converted)
        }

        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// 録音停止 → WAVデータを返す
    func stop() -> Data {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
        // タップ解除と入れ違いに来たコールバックが停止後に発火しないよう先に切る
        onBuffer = nil
        onLevel = nil
        lock.lock()
        let captured = samples
        samples.removeAll()
        lock.unlock()
        lastPeak = captured.reduce(0) { max($0, abs($1)) }
        return WAV.encode(samples: captured)
    }

    /// 音量（RMS）を 0〜1 に正規化して間引いて通知する。
    /// 生のRMSは静かな発話だと 0.01 程度にしかならないので、対数寄りに持ち上げて見た目を作る
    private func emitLevel(from samples: [Float]) {
        guard let onLevel, !samples.isEmpty else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastLevelSentAt >= 0.05 else { return }
        lastLevelSentAt = now

        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let rms = (sum / Float(samples.count)).squareRoot()
        // -50dB を下限として 0〜1 にマップ
        let db = 20 * log10(max(rms, 0.0000_1))
        let level = max(0, min(1, (db + 50) / 50))
        DispatchQueue.main.async { onLevel(level) }
    }
}
