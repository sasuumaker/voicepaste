import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import VoicePasteCore

/// マイクの音を取り、16kHz モノラル Float32 に変換して溜める。
///
/// マイクは CoreAudio の入力用音声ユニット（AUHAL）を直接開いて取る。AVAudioEngine は使わない。
/// AVAudioEngine は作った直後に、裏の別スレッドで入力部品の装置を「既定の出力 → 既定の仮想まとめ装置」へ
/// 自分で切り替える。こちらがマイクを指定する切り替えと同時に走るため、まれに両方の切り替えが壊れ、
/// 次の録音開始で `inputNode` の中から戻らなくなった（2026-09-27。メニューもホットキーも効かなくなった）。
/// AUHAL なら装置の指定はこちらが1回・1スレッド・開始前に行うだけで、裏で切り替わることもない
final class AudioRecorder {
    private var capture: InputCapture?
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
        case audioUnit(step: String, status: OSStatus)
        var errorDescription: String? {
            switch self {
            case .noInput: return "マイク入力を取得できません（マイク権限を確認してください）"
            case .deviceNotSelectable(let status): return "選んだマイクを録音に使えません（CoreAudio \(status)）。設定でマイクを変えてください"
            case .audioUnit(let step, let status): return "マイクを開けません（\(step)で CoreAudio \(status)）"
            }
        }
    }

    /// 直近の録音の音量ピーク（0〜1）。「マイクが音を拾えていたか」を診断ログで確かめるため。
    /// 0.00 なら無音（選んだマイクが音を拾っていない／ミュート）
    private(set) var lastPeak: Float = 0

    /// 直近の録音に「声」が入っていたかの測定結果。何も言わずに止めた録音を Groq へ送らないために使う
    private(set) var lastSpeech: SpeechPresence.Measurement?

    var recordedSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(samples.count) / 16000.0
    }

    /// - Parameters:
    ///   - deviceID: 録音に使うマイク。nil なら macOS の既定入力
    ///   - onCaptureLive: 最初の音声バッファが届いた（＝実際に録音が生きた）タイミングで
    ///     メインスレッドから1回だけ呼ばれる。開始音はここで鳴らすことで喋り出しの欠けを防ぐ
    func start(deviceID: AudioDeviceID?, onCaptureLive: @escaping () -> Void) throws {
        // 前の録音が閉じられずに残っていたら先に閉じる（開いたままだとマイクを握り続ける）
        capture?.close()
        capture = nil
        lock.lock()
        samples.removeAll()
        lock.unlock()
        self.onCaptureLive = onCaptureLive
        self.captureLiveFired = false
        self.lastLevelSentAt = 0

        guard let device = deviceID ?? AudioInputDevices.systemDefaultID() else {
            throw RecorderError.noInput
        }
        let capture = try InputCapture.open(device: device, targetFormat: targetFormat) { [weak self] output in
            self?.receive(output)
        }
        do {
            try capture.start()
        } catch {
            capture.close()
            throw error
        }
        self.capture = capture
    }

    /// 録音停止 → WAVデータを返す
    func stop() -> Data {
        // close() が戻った後はオーディオスレッドからの呼び出しが来ない
        capture?.close()
        capture = nil
        onBuffer = nil
        onLevel = nil
        lock.lock()
        let captured = samples
        samples.removeAll()
        lock.unlock()
        lastPeak = captured.reduce(0) { max($0, abs($1)) }
        lastSpeech = SpeechPresence.measure(samples: captured)
        return WAV.encode(samples: captured)
    }

    /// 16kHzモノラルに変換済みのバッファを受け取る。オーディオスレッドから呼ばれる
    private func receive(_ output: AVAudioPCMBuffer) {
        if !captureLiveFired {
            captureLiveFired = true
            let callback = onCaptureLive
            DispatchQueue.main.async { callback?() }
        }
        guard let channel = output.floatChannelData?[0] else { return }
        let converted = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        lock.lock()
        samples.append(contentsOf: converted)
        lock.unlock()

        // 変換済みバッファは毎回この場で作った自前のものなので、そのまま渡して安全
        onBuffer?(output)
        emitLevel(from: converted)
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

/// 1回の録音で開いた入力用の音声ユニット（AUHAL）一式。
/// オーディオスレッドのコールバックはこのオブジェクトだけを触る。
/// 片付けは `close()` が「止める → 破棄する」の順で行い、破棄が戻った後はコールバックが来ない
private final class InputCapture {
    private let unit: AudioUnit
    /// 装置の形式（Float32・非インターリーブ・装置のサンプルレート）で受ける入れ物
    private let deviceBuffer: AVAudioPCMBuffer
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private let ratio: Double
    private let deliver: (AVAudioPCMBuffer) -> Void
    private var closed = false

    private init(unit: AudioUnit, deviceBuffer: AVAudioPCMBuffer, converter: AVAudioConverter,
                 targetFormat: AVAudioFormat, deliver: @escaping (AVAudioPCMBuffer) -> Void) {
        self.unit = unit
        self.deviceBuffer = deviceBuffer
        self.converter = converter
        self.targetFormat = targetFormat
        self.ratio = targetFormat.sampleRate / deviceBuffer.format.sampleRate
        self.deliver = deliver
    }

    /// 音声ユニットを作り、マイクを指定して、開始できる状態まで準備する（まだ音は流れない）
    static func open(device: AudioDeviceID, targetFormat: AVAudioFormat,
                     deliver: @escaping (AVAudioPCMBuffer) -> Void) throws -> InputCapture {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioRecorder.RecorderError.noInput
        }
        var created: AudioUnit?
        try check(AudioComponentInstanceNew(component, &created), "音声ユニットの作成")
        guard let unit = created else { throw AudioRecorder.RecorderError.noInput }

        do {
            let u32Size = UInt32(MemoryLayout<UInt32>.size)
            // 入力（要素1）を有効に、出力（要素0）を無効にする。装置の指定より先に行う決まり
            var on: UInt32 = 1
            var off: UInt32 = 0
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                                           &on, u32Size), "入力の有効化")
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                                           &off, u32Size), "出力の無効化")

            var id = device
            let selected = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                                &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard selected == noErr else { throw AudioRecorder.RecorderError.deviceNotSelectable(selected) }

            // 形式（サンプルレート・チャンネル数）は機器ごとに違うので、指定してから読む
            var hardware = AudioStreamBasicDescription()
            var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
                                           &hardware, &asbdSize), "マイクの形式の取得")
            guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
                  let deviceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                   sampleRate: hardware.mSampleRate,
                                                   channels: hardware.mChannelsPerFrame,
                                                   interleaved: false)
            else { throw AudioRecorder.RecorderError.noInput }

            // こちらが受け取る形式。サンプルレートは装置と同じにする（AUHAL は入力側でレート変換をしない）。
            // 16kHz への変換は AVAudioConverter が行う
            var client = deviceFormat.streamDescription.pointee
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                           &client, asbdSize), "受け取る形式の指定")

            var maxFrames: UInt32 = 0
            var maxFramesSize = u32Size
            _ = AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                     &maxFrames, &maxFramesSize)
            guard let deviceBuffer = AVAudioPCMBuffer(pcmFormat: deviceFormat, frameCapacity: max(maxFrames, 16384)),
                  let converter = AVAudioConverter(from: deviceFormat, to: targetFormat)
            else { throw AudioRecorder.RecorderError.noInput }

            let capture = InputCapture(unit: unit, deviceBuffer: deviceBuffer, converter: converter,
                                       targetFormat: targetFormat, deliver: deliver)
            // コールバックに渡すのは参照を増やさない生のポインタ。capture の寿命は AudioRecorder が持ち、
            // close() で音声ユニットを破棄してから手放すので、破棄前に解放されることはない
            var callback = AURenderCallbackStruct(inputProc: inputCaptureCallback,
                                                  inputProcRefCon: Unmanaged.passUnretained(capture).toOpaque())
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                           &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                      "受け取り処理の登録")
            try check(AudioUnitInitialize(unit), "音声ユニットの初期化")
            return capture
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    func start() throws {
        try Self.check(AudioOutputUnitStart(unit), "録音の開始")
    }

    /// 止めて破棄する。2回呼んでもよい
    func close() {
        guard !closed else { return }
        closed = true
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    /// マイクから届いた1回ぶんを取り出し、16kHzモノラルに変換して渡す。オーディオスレッドから呼ばれる
    fileprivate func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            timeStamp: UnsafePointer<AudioTimeStamp>,
                            bus: UInt32, frames: UInt32) -> OSStatus {
        guard frames <= deviceBuffer.frameCapacity else { return kAudioUnitErr_TooManyFramesToProcess }
        deviceBuffer.frameLength = frames
        let buffers = UnsafeMutableAudioBufferListPointer(deviceBuffer.mutableAudioBufferList)
        for index in 0..<buffers.count {
            buffers[index].mDataByteSize = frames * UInt32(MemoryLayout<Float>.size)
        }
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, deviceBuffer.mutableAudioBufferList)
        guard status == noErr else { return status }

        let capacity = AVAudioFrameCount(Double(frames) * ratio + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return noErr }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { [deviceBuffer] _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return deviceBuffer
        }
        guard error == nil else { return noErr }
        deliver(output)
        return noErr
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw AudioRecorder.RecorderError.audioUnit(step: step, status: status) }
    }
}

/// AUHAL の入力コールバック（C の関数ポインタなので、何も捕まえないクロージャで書く）
private let inputCaptureCallback: AURenderCallback = { refCon, flags, timeStamp, bus, frames, _ in
    let capture = Unmanaged<InputCapture>.fromOpaque(refCon).takeUnretainedValue()
    return capture.render(flags: flags, timeStamp: timeStamp, bus: bus, frames: frames)
}
