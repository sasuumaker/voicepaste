import AVFoundation
import Foundation
import Speech
import VoicePasteCore

/// 録音中の「いま喋っている内容」を画面下のポップアップに出すためのリアルタイム認識。
///
/// これは**表示専用**。確定テキストは従来どおり Groq Whisper（言語自動判定＋整形）が作る。
/// ここで内蔵認識を使う理由:
/// - 追加のAPI課金もレート消費もない
/// - オンデバイスなので音声が外に出ない
/// - 部分結果が数百ミリ秒で返るのでストリーミング表示に向く
///
/// 制約: 内蔵認識は言語を1つ選ぶ必要があるので、字幕は設定した言語で出る。
/// 設定と違う言語で喋ると字幕は崩れるが、確定テキストはGroqの自動判定なので正しく出る。
final class LiveTranscriber {
    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var running = false
    /// 認識が区切りを打つたびに、そこまでの文を積んでいく。
    /// これが無いと区切りのたびに表示が空に戻り、喋った内容が消えて見える
    private var finalizedText = ""
    /// いま認識中の発話の途中経過。次の発話に切り替わった時点で `finalizedText` へ積む
    private var currentText = ""
    /// いま認識中の発話が音声のどこから始まっているか。ここが前に進んだら発話が切り替わった合図
    private var lastSegmentStart: TimeInterval = -1
    private var restartCount = 0
    private let lock = NSLock()
    /// 認識結果の推移。録音を止めたときにまとめてログへ流す（毎回書くと重いので溜めておく）
    private var trace: [String] = []

    /// 認識が一度も実を結ばないまま張り直し続けた場合の歯止め。
    /// 部分結果が1つでも返ったら 0 に戻すので、普通に喋っている限り上限には当たらない
    private static let restartLimit = 20

    /// 部分結果。メインスレッドで呼ばれる
    var onText: ((String) -> Void)?

    init(localeIdentifier: String) {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
    }

    // MARK: - 権限

    static var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    static var isUndetermined: Bool {
        SFSpeechRecognizer.authorizationStatus() == .notDetermined
    }

    static func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { completion(status == .authorized) }
        }
    }

    /// オンデバイスで動かせるときだけ使う。
    /// 端末で完結できない言語のときにAppleのサーバーへ音声を送るのは、
    /// このアプリの前提（音声を外に出さない）に反するので使わない
    var canRunOnDevice: Bool {
        guard let recognizer, recognizer.isAvailable else { return false }
        return recognizer.supportsOnDeviceRecognition
    }

    /// - Returns: 開始できなかった理由。成功なら nil
    @discardableResult
    func start() -> String? {
        guard let recognizer else { return "この言語の音声認識に対応していません" }
        guard Self.isAuthorized else { return "音声認識の許可がありません" }
        guard recognizer.isAvailable else { return "音声認識をいま利用できません" }
        guard recognizer.supportsOnDeviceRecognition else {
            return "この言語は端末内で認識できないため字幕を出しません"
        }

        finalizedText = ""
        currentText = ""
        restartCount = 0
        running = true
        beginTask(on: recognizer)
        return nil
    }

    /// 認識タスクを1本張る。区切りが来たら積んでから張り直す
    private func beginTask(on recognizer: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation

        lock.lock()
        self.request = request
        lock.unlock()
        // 新しいタスクの音声は先頭から数え直しになるので、切り替わり判定の基準も戻す
        lastSegmentStart = -1

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.running else { return }
                if let result {
                    // 認識が生きている証拠。暴走の歯止めはここで戻す
                    self.restartCount = 0
                    self.consume(result)
                    if result.isFinal {
                        self.commitAndRestart(on: recognizer, reason: "区切り")
                    }
                } else if let error {
                    // 無音が続くと認識はエラーで打ち切られる。ここでも積まないと、
                    // 止まった瞬間にそれまでの文章が消える（実測・2026-08-02）
                    self.commitAndRestart(on: recognizer, reason: "打ち切り: \(error.localizedDescription)")
                }
            }
        }
    }

    /// 部分結果を1つ取り込む。
    ///
    /// 要点: 少し黙ると、認識タスクは**終わらないまま** `bestTranscription` の中身だけが
    /// 次の発話用に作り直される（`isFinal` もエラーも来ない。実測・2026-08-02）。
    /// そのままだと表示が新しい発話だけに置き換わり、それまでの文章が消える。
    /// タスクの終了を待たず、結果そのものから発話の切り替わりを見つけて積む。
    private func consume(_ result: SFSpeechRecognitionResult) {
        let transcription = result.bestTranscription
        let text = transcription.formattedString
        let segmentStart = transcription.segments.first?.timestamp ?? 0

        if isNewUtterance(segmentStart: segmentStart, text: text) {
            finalizedText = TextJoin.concat(finalizedText, currentText)
            currentText = ""
            note(String(format: "t=%.2f len=%d 新しい発話（ここまでを積む: %d字）",
                        segmentStart, text.count, finalizedText.count))
        } else {
            note(String(format: "t=%.2f len=%d", segmentStart, text.count))
        }

        lastSegmentStart = segmentStart
        currentText = text
        onText?(TextJoin.concat(finalizedText, currentText))
    }

    /// 判定の本体は `UtteranceBoundary`（実測データで再生テストしてある）
    private func isNewUtterance(segmentStart: TimeInterval, text: String) -> Bool {
        UtteranceBoundary.isNew(
            previousText: currentText,
            previousSegmentStart: lastSegmentStart,
            text: text,
            segmentStart: segmentStart
        )
    }

    private func note(_ line: String) {
        trace.append(line)
        if trace.count > 200 { trace.removeFirst(trace.count - 200) }
    }

    /// タスクが終わった理由によらず、途中経過を積んでから張り直す。
    /// 積んだ内容をそのまま表示し直すので、張り直しの間も文章は消えない
    private func commitAndRestart(on recognizer: SFSpeechRecognizer, reason: String) {
        finalizedText = TextJoin.concat(finalizedText, currentText)
        currentText = ""
        if !finalizedText.isEmpty { onText?(finalizedText) }
        CaptionDebugLog.write(reason: reason, kept: finalizedText, restartCount: restartCount)
        restart(on: recognizer)
    }

    private func restart(on recognizer: SFSpeechRecognizer) {
        guard running, restartCount < Self.restartLimit else { return }
        restartCount += 1
        lock.lock()
        request?.endAudio()
        request = nil
        lock.unlock()
        task?.cancel()
        task = nil
        beginTask(on: recognizer)
    }

    /// オーディオスレッドから呼ばれる
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = request
        lock.unlock()
        current?.append(buffer)
    }

    func stop() {
        running = false
        if !trace.isEmpty {
            CaptionDebugLog.writeTrace(trace, finalText: TextJoin.concat(finalizedText, currentText))
            trace.removeAll()
        }
        lock.lock()
        request?.endAudio()
        request = nil
        lock.unlock()
        task?.cancel()
        task = nil
        onText = nil
    }
}
