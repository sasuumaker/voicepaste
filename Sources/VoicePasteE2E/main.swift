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

        // ---- 4. 無音音声の全経路（録音誤爆シミュレーション）----
        print("4. 無音音声の全経路")
        let silence = WAV.encode(samples: [Float](repeating: 0, count: 16000))  // 1秒の無音
        let silentTranscript = try await whisper.transcribe(wav: silence)
        print("   無音の認識結果: \"\(silentTranscript)\"")
        if silentTranscript.isEmpty {
            expect(true, "無音→空文字（アプリ側は何も貼り付けない経路）")
        } else {
            // 幻聴が出た場合: 編集に流れても本文が保持されること
            let result = try await editor.edit(selection: memo, instruction: silentTranscript)
            let preserved = result == memo
                || (result.contains("料金プラン") && result.contains("8月末") && result.contains("TikTok"))
            expect(preserved, "無音の幻聴「\(silentTranscript)」でも本文が保持される",
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
