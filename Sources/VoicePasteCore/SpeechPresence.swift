import Foundation

/// 録音した音に「人の声」が入っていたかを判定する（純粋関数・UIなし）。
///
/// 何も言わずに録音を止めると、Whisperは無音やノイズから「ご視聴ありがとうございました」「はい」といった
/// 文を作り出し、それがそのまま貼られていた（実測 2026-09-03: transcript-debug.log の該当3件は
/// すべて音量ピーク 0.00〜0.04）。Groqへ送る前にここで止めれば、幻覚の文が貼られることも、
/// 無駄なAPI呼び出しも無くなる。
///
/// 判定の仕組み:
/// 1. 20msごとの音量（RMS）を並べ、静かなほうから20%の位置を「床」（部屋のノイズの大きさ）とする
/// 2. 床の1.5倍以上（下限 0.002）の音量が **4コマ（80ms）以上続いた区間** があれば「声あり」
///
/// なぜ「続いた長さ」で見るか（合成波形での試作 2026-09-03）:
/// - ピーク音量だけでは切り分けられない。幻覚が出た録音のピークは 0.04、本物の短い発話「おわり。」は 0.03
/// - ホットキーを押すキーの音は内蔵マイクが拾い、床を超えるが 1〜2コマ（20〜40ms）で消える
/// - 本物の発話は小声の「はい」でも4コマ以上続く（ピーク0.05・床0.01 で 0.08秒）
/// - 換気音のような定常的なノイズは床の1.5倍を超えない（20msごとのRMSのばらつきは数%）
/// - 息がマイクに直接かかると声と区別できない（0.4秒続く）。これは `KnownHallucinations` に任せる
///
/// 倒し方: 迷ったら「声あり」に倒す（本物の発話を捨てるほうが、幻覚が1文貼られるより痛い）。
/// 床そのものが高い（録音全体が音で埋まっていて静かな部分が無い）ときも声ありに倒す。
/// 床の1.5倍（約+3.5dB）に満たない声は Whisper でも正しく聞き取れない
/// （合成音声で実測: ピーク0.03・床0.01 の「おわり」→「おやり」）。
public enum SpeechPresence {
    public struct Measurement: Equatable {
        /// 20msごとの音量（RMS）の、静かなほうから20%の位置。部屋のノイズの大きさ
        public let noiseFloor: Float
        /// 20msごとの音量（RMS）の最大値
        public let maxRMS: Float
        /// 床の1.5倍以上が続いた最長の時間（秒）
        public let longestRunSeconds: Double
        /// 床の1.5倍以上だった時間の合計（秒）
        public let activeSeconds: Double
        /// 声が入っていたか
        public let hasSpeech: Bool

        /// 診断ログ用の1行。閾値を見直すときの材料になるよう、判定に使った数値を全部出す
        public var summary: String {
            String(format: "声のある区間 最長%.2f秒（合計%.2f秒）／床%.4f／最大%.4f",
                   longestRunSeconds, activeSeconds, noiseFloor, maxRMS)
        }
    }

    /// 1コマの長さ（秒）。20ms
    public static let frameSeconds = 0.02
    /// 床＝この割合の位置（静かなほうから）
    public static let floorPercentile = 0.2
    /// 床の何倍以上を「音がある」と見るか
    public static let ratioOverFloor: Float = 1.5
    /// 閾値の下限（-54dBFS）。デジタル無音のわずかなゆらぎを声と見ないため
    public static let absoluteMinimumRMS: Float = 0.002
    /// 「声あり」に要る連続コマ数。4コマ＝80ms
    public static let minimumRunFrames = 4
    /// 床そのものがこれ以上なら、録音全体が音で埋まっている（静かな部分が無い）ので声ありに倒す。
    /// 床を基準にした判定は「静かな部分がある」前提なので、その前提が崩れたときの逃げ道。
    /// 内蔵マイクの部屋のノイズは 0.01 前後（幻覚が出た録音のピーク 0.04 から逆算）なので、その1.5倍
    public static let loudFloorRMS: Float = 0.015

    public static func measure(samples: [Float], sampleRate: Int = 16000) -> Measurement {
        let frame = max(1, Int(Double(sampleRate) * frameSeconds))
        var rmsPerFrame: [Float] = []
        rmsPerFrame.reserveCapacity(samples.count / frame + 1)
        var start = 0
        while start + frame <= samples.count {
            var sum: Float = 0
            for index in start..<(start + frame) {
                let sample = samples[index]
                sum += sample * sample
            }
            rmsPerFrame.append((sum / Float(frame)).squareRoot())
            start += frame
        }
        guard !rmsPerFrame.isEmpty else {
            return Measurement(noiseFloor: 0, maxRMS: 0, longestRunSeconds: 0, activeSeconds: 0, hasSpeech: false)
        }

        let sorted = rmsPerFrame.sorted()
        let floorIndex = min(sorted.count - 1, Int(Double(sorted.count) * floorPercentile))
        let noiseFloor = sorted[floorIndex]
        let threshold = max(absoluteMinimumRMS, noiseFloor * ratioOverFloor)

        var run = 0
        var longest = 0
        var active = 0
        for rms in rmsPerFrame {
            if rms >= threshold {
                run += 1
                active += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        let secondsPerFrame = Double(frame) / Double(sampleRate)
        return Measurement(
            noiseFloor: noiseFloor,
            maxRMS: sorted[sorted.count - 1],
            longestRunSeconds: Double(longest) * secondsPerFrame,
            activeSeconds: Double(active) * secondsPerFrame,
            hasSpeech: longest >= minimumRunFrames || noiseFloor >= loudFloorRMS
        )
    }
}
