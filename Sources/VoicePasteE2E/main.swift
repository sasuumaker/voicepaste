import Foundation
import VoicePasteCore

// 実Groq APIを叩くE2Eテスト。
// アプリの実行経路のうちUI以外（音声→文字起こし→編集→貼り付け直前）を全部通す。
// 実行: swift run VoicePasteE2E
//
// 検証の狙い:
// 1. 正常系: 音声指示で選択テキストが箇条書きに構造化されること
// 2. 事故再現系: Whisperの幻聴（無音時に "you?" 等を出力する既知の癖）が
//    編集指示として流れ込んでも、選択テキストが破壊されないこと

var failures = 0
var passed = 0

func expect(_ condition: Bool, _ label: String, detail: String = "") {
    if condition {
        passed += 1
        print("  ✅ \(label)")
    } else {
        failures += 1
        print("  ❌ \(label)\(detail.isEmpty ? "" : "\n     → \(detail)")")
    }
}

func run(_ launchPath: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "e2e", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "\(launchPath) \(arguments.joined(separator: " ")) failed"])
    }
}

/// macOSのTTSで指示音声を合成し、アプリと同じ16kHzモノラルWAVにして返す
func synthesizeSpeech(_ text: String, voice: String = "Kyoko") throws -> Data {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voicepaste-e2e")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let aiff = dir.appendingPathComponent("\(UUID().uuidString).aiff").path
    let wav = dir.appendingPathComponent("\(UUID().uuidString).wav").path
    try run("/usr/bin/say", ["-v", voice, "-o", aiff, text])
    try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, wav])
    return try Data(contentsOf: URL(fileURLWithPath: wav))
}

/// WAV（16bit PCM モノラル）を Float サンプル列に戻す。afconvert の出力を SpeechPresence にかけるため
func decodeWAV(_ data: Data) -> [Float] {
    var offset = 12  // "RIFF" + size + "WAVE"
    while offset + 8 <= data.count {
        let id = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
        let size = Int(data[(offset + 4)..<(offset + 8)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        if id == "data" {
            let body = data[(offset + 8)..<min(data.count, offset + 8 + size)]
            return stride(from: body.startIndex, to: body.endIndex - 1, by: 2).map { index in
                let value = body[index..<(index + 2)].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
                return Float(Int16(littleEndian: value)) / 32767
            }
        }
        offset += 8 + size + (size % 2)
    }
    return []
}

/// 結果が毎回同じになる乱数（線形合同法 + Box-Muller）。部屋のノイズの再現用
struct TestNoise {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
    mutating func gaussian(_ sigma: Float) -> Float {
        let u1 = max(next(), 1e-12)
        let u2 = next()
        return Float((-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)) * sigma
    }
}

func gaussianNoise(seconds: Double, sigma: Float, seed: UInt64 = 12345) -> [Float] {
    var generator = TestNoise(state: seed)
    return (0..<Int(seconds * 16000)).map { _ in generator.gaussian(sigma) }
}

/// 合成音声を指定のピーク音量まで下げ、前後に無音を足し、部屋のノイズを重ねる（小声の発話の再現）
func synthesizeSamples(_ text: String, peak: Float, noiseSigma: Float, pad: Double = 0.4) throws -> [Float] {
    let speech = decodeWAV(try synthesizeSpeech(text))
    let maxAbs = speech.map(abs).max() ?? 1
    var generator = TestNoise(state: 7)
    let padding = [Float](repeating: 0, count: Int(pad * 16000))
    return (padding + speech + padding).map { $0 / maxAbs * peak + generator.gaussian(noiseSigma) }
}

// MARK: - セットアップ

guard let apiKey = Config.load().resolvedAPIKey else {
    print("❌ APIキーがありません（config.json か GROQ_API_KEY）")
    exit(2)
}
let config = Config.load()
let whisper = GroqClient(apiKey: apiKey, model: config.model)
let editor = GroqClient(apiKey: apiKey, model: config.cleanup_model)

// ユーザーの実シナリオ: 書いた文章を選択して「箇条書きで構造的に整理して」
let memo = """
    今日の打ち合わせでは、まず新しいアプリの料金プランについて話し合い、月額500円の読み放題プランと年額プランの2本立てにする方向になった。次にリリース時期は8月末を目標にすることが決まり、マーケティングはTikTokのオーガニック投稿を中心に進めることになった。残っている課題は決済まわりの実装とプライバシーポリシーの整備の2つ。
    """
let instructionText = "全体の内容を箇条書きで構造的に整理し直して"

func looksLikeBulletList(_ text: String) -> Bool {
    let bulletLines = text.split(separator: "\n").filter {
        let t = $0.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("-") || t.hasPrefix("・") || t.hasPrefix("•") || t.hasPrefix("*") || t.hasPrefix("１")
            || (t.first?.isNumber == true && (t.dropFirst().first == "." || t.dropFirst().first == "、"))
    }
    return bulletLines.count >= 3
}

let semaphore = DispatchSemaphore(value: 0)
Task {
    do {
        // ---- 1. 音声合成→文字起こし（指示がちゃんと文字になるか）----
        print("1. TTS音声の文字起こし")
        let instructionWav = try synthesizeSpeech(instructionText)
        let transcript = try await whisper.transcribe(wav: instructionWav)
        print("   認識結果: \(transcript)")
        // 「箇条書き」は同音の「過剰書き」等に誤変換されることがある（実際に確認済み）。
        // 音として正しく拾えていればOK。誤変換の読み替えは編集プロンプト側の責務（ケース2で検証）
        let phonetic = ["箇条書き", "過剰書き", "か条書き", "かじょうがき"]
        expect(phonetic.contains { transcript.contains($0) } && transcript.contains("整理"),
               "指示音声を音として正しく認識できる（同音誤変換は許容）", detail: "認識結果: \(transcript)")

        // ---- 2. 正常系: 認識した指示で編集（全経路）----
        print("2. 編集の正常系（音声→認識→編集の全経路）")
        let edited = try await editor.edit(selection: memo, instruction: transcript)
        print("   編集結果:\n\(edited.split(separator: "\n").map { "   | \($0)" }.joined(separator: "\n"))")
        expect(looksLikeBulletList(edited), "編集結果が箇条書きになっている", detail: edited)
        expect(edited.contains("500円") || edited.contains("料金"), "内容（料金プラン）が保持されている", detail: edited)
        expect(edited.contains("8月末") || edited.contains("リリース"), "内容（リリース時期）が保持されている", detail: edited)
        expect(edited.contains("TikTok"), "内容（マーケ方針）が保持されている", detail: edited)

        // ---- 3. 事故再現系: Whisper幻聴が指示に化けたケース ----
        // 実際に起きた事故: 選択部分が「you？」に置き換わった
        print("3. 事故再現系（壊れた指示で選択テキストが破壊されないか）")
        for broken in ["you?", "Thank you.", "ご視聴ありがとうございました", "はい"] {
            let result = try await editor.edit(selection: memo, instruction: broken)
            let preserved = result == memo
                || (result.contains("料金プラン") && result.contains("8月末") && result.contains("TikTok"))
            expect(preserved, "壊れた指示「\(broken)」で本文が保持される",
                   detail: "出力: \(result.prefix(120))")
        }

        // ---- 4. 何も言わなかったとき（無音・部屋のノイズ・小声）の全経路 ----
        // 実際に起きた事故: 何も言わずに止めると「ご視聴ありがとうございました。」が貼られた（2026-09-03）
        print("4. 何も言わなかったときの全経路")
        // 4-1. 声なし判定（Groqへ送らずに終わる経路）
        let silence = [Float](repeating: 0, count: 16000)  // 1秒の無音
        expect(!SpeechPresence.measure(samples: silence).hasSpeech, "無音1秒 → 声なし（Groqへ送らない）")
        let roomNoise = gaussianNoise(seconds: 1.5, sigma: 0.01)  // 内蔵マイクでピーク0.04程度の部屋のノイズ
        let roomMeasure = SpeechPresence.measure(samples: roomNoise)
        expect(!roomMeasure.hasSpeech, "部屋のノイズ1.5秒（RMS 0.01）→ 声なし（Groqへ送らない）", detail: roomMeasure.summary)

        // 4-2. すり抜けて送ってしまった場合の歯止め: Whisper が作る文は既知の幻覚句として捨てられること
        let silentTranscript = try await whisper.transcribe(wav: WAV.encode(samples: silence))
        print("   無音の認識結果: \"\(silentTranscript)\"")
        expect(silentTranscript.isEmpty || KnownHallucinations.isKnownPhrase(silentTranscript),
               "無音 → 空文字か既知の幻覚句（どちらも貼らない）", detail: silentTranscript)
        // 部屋のノイズは Whisper が「はい。」のような短い相槌を作ることがあり、これは幻覚句の一覧に載せていない
        // （本物と区別できない）。声なし判定で送らないことが歯止めなので、判断は2段を合わせて見る
        let noisyTranscript = try await whisper.transcribe(wav: WAV.encode(samples: roomNoise))
        print("   部屋のノイズをもし送ったら: \"\(noisyTranscript)\"（実際には声なし判定で送らない）")
        let wouldPasteNoise = roomMeasure.hasSpeech && !noisyTranscript.isEmpty
            && !KnownHallucinations.isKnownPhrase(noisyTranscript)
        expect(!wouldPasteNoise, "部屋のノイズ → 貼られない（声なし判定か幻覚句のどちらかで止まる）", detail: noisyTranscript)

        // 4-3. 小声の短い発話は捨てない: 合成音声「はい」をピーク0.06まで下げ、部屋のノイズ（RMS 0.01）を重ねる
        let quietYes = try synthesizeSamples("はい", peak: 0.06, noiseSigma: 0.01)
        let quietMeasure = SpeechPresence.measure(samples: quietYes)
        expect(quietMeasure.hasSpeech, "小声の「はい」（ピーク0.06・床0.01）→ 声あり（送る）", detail: quietMeasure.summary)
        let quietTranscript = try await whisper.transcribe(wav: WAV.encode(samples: quietYes))
        print("   小声の「はい」の認識結果: \"\(quietTranscript)\"")
        expect(!quietTranscript.isEmpty && !KnownHallucinations.isKnownPhrase(quietTranscript),
               "小声の「はい」は聞き取られ、幻覚句とも一致しない（貼られる）", detail: quietTranscript)

        // 4-4. 幻覚句が編集モードに流れ込んでも本文が保持される（従来の検証）
        if !silentTranscript.isEmpty {
            let result = try await editor.edit(selection: memo, instruction: silentTranscript)
            let preserved = result == memo
                || (result.contains("料金プラン") && result.contains("8月末") && result.contains("TikTok"))
            expect(preserved, "無音の幻聴「\(silentTranscript)」が編集に流れても本文が保持される",
                   detail: "出力: \(result.prefix(120))")
        }

        // ---- 5. 英語指示（言語をまたぐケース）----
        print("5. 英語指示")
        let en = try await editor.edit(selection: memo, instruction: "make this a bulleted list")
        expect(looksLikeBulletList(en), "英語指示でも箇条書きになる", detail: en)
        expect(en.contains("TikTok") && (en.contains("500円") || en.contains("料金")),
               "英語指示でも日本語の内容が保持される", detail: en)
    } catch {
        failures += 1
        print("  ❌ 例外: \(error.localizedDescription)")
    }
    semaphore.signal()
}
semaphore.wait()

print("")
print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
