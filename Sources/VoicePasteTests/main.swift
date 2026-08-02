import Foundation
import VoicePasteCore

// XCTest非依存の素朴なテストランナー（CLT環境用）
// 実行: swift run VoicePasteTests

var failures = 0
var passed = 0

func expect(_ condition: Bool, _ label: String, file: String = #file, line: Int = #line) {
    if condition {
        passed += 1
        print("  ✅ \(label)")
    } else {
        failures += 1
        print("  ❌ \(label)  (\(file):\(line))")
    }
}

print("HotKeySpec")
expect(
    HotKeySpec.parse("ctrl+cmd+v") == HotKeySpec(keyCode: 9, carbonModifiers: HotKeySpec.control | HotKeySpec.cmd),
    "parse ctrl+cmd+v"
)
expect(
    HotKeySpec.parse("option+space") == HotKeySpec(keyCode: 49, carbonModifiers: HotKeySpec.option),
    "parse option+space"
)
expect(HotKeySpec.parse("alt+space") == HotKeySpec.parse("opt+space"), "alt/opt aliases")
expect(
    HotKeySpec.parse("Command+Shift+F13")?.carbonModifiers == HotKeySpec.cmd | HotKeySpec.shift,
    "case-insensitive, F-keys"
)
expect(HotKeySpec.parse("hyper+v") == nil, "unknown modifier rejected")
expect(HotKeySpec.parse("ctrl+cmd+unknownkey") == nil, "unknown key rejected")
expect(HotKeySpec.parse("") == nil, "empty rejected")

print("HotKeySpec 逆引き（設定画面でキー入力→設定文字列）")
expect(HotKeySpec.keyName(forKeyCode: 44) == "slash", "keyCode 44 -> slash")
expect(HotKeySpec.keyName(forKeyCode: 999) == nil, "unknown keyCode -> nil")
// 設定画面で押されたキーを文字列にして、もう一度読み直しても同じになる（往復して壊れない）
for source in ["cmd+slash", "ctrl+cmd+v", "ctrl+slash", "option+space", "shift+cmd+f13"] {
    let spec = HotKeySpec.parse(source)
    let roundTripped = spec?.configString.flatMap { HotKeySpec.parse($0) }
    expect(roundTripped == spec, "round trip \(source)")
}
expect(HotKeySpec.parse("cmd+slash")?.configString == "cmd+slash", "configString cmd+slash")
// 修飾キーの並び順は入力順によらず ⌃⌥⇧⌘ に揃える
expect(HotKeySpec.parse("cmd+ctrl+v")?.configString == "ctrl+cmd+v", "modifier order normalized")
expect(HotKeySpec.symbolString(for: "cmd+slash") == "⌘/", "symbol ⌘/")
expect(HotKeySpec.symbolString(for: "ctrl+cmd+v") == "⌃⌘V", "symbol ⌃⌘V")
expect(HotKeySpec.symbolString(for: "option+space") == "⌥Space", "symbol ⌥Space")
expect(HotKeySpec.symbolString(for: "bogus") == "bogus", "unparseable symbol falls back to raw")
// 修飾キーなしは通常のキー入力を丸ごと奪うので設定画面で弾く
expect(HotKeySpec(keyCode: 44, carbonModifiers: 0).hasModifier == false, "no modifier detected")
expect(HotKeySpec.parse("cmd+slash")?.hasModifier == true, "modifier detected")
// 取り消し用の Esc（録音中だけ登録する。設定には出さないのでコード側から parse する）
expect(HotKeySpec.parse("escape") == HotKeySpec(keyCode: 53, carbonModifiers: 0), "parse escape (取り消し用)")
expect(HotKeySpec.symbolString(for: "escape") == "⎋", "symbol ⎋")

print("WAV")
let samples: [Float] = [0.0, 0.5, -0.5, 1.0]
let wav = WAV.encode(samples: samples, sampleRate: 16000)
expect(wav.count == 44 + samples.count * 2, "size = 44 byte header + 2 bytes/sample")
expect(String(data: wav.subdata(in: 0..<4), encoding: .ascii) == "RIFF", "RIFF magic")
expect(String(data: wav.subdata(in: 8..<12), encoding: .ascii) == "WAVE", "WAVE magic")
expect(String(data: wav.subdata(in: 36..<40), encoding: .ascii) == "data", "data chunk")
let rate = wav.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: UInt32.self) }
expect(UInt32(littleEndian: rate) == 16000, "sample rate 16000")
let lastSample = wav.subdata(in: (wav.count - 2)..<wav.count).withUnsafeBytes { $0.load(as: Int16.self) }
expect(Int16(littleEndian: lastSample) == 32767, "clamp 1.0 -> 32767")

print("GroqClient.makeRequest")
let request = GroqClient.makeRequest(
    wav: Data([0x01, 0x02, 0x03]),
    apiKey: "test-key",
    model: "whisper-large-v3-turbo",
    boundary: "BOUNDARY"
)
expect(request.url?.absoluteString == "https://api.groq.com/openai/v1/audio/transcriptions", "endpoint URL")
expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key", "auth header")
expect(
    request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=BOUNDARY",
    "content-type header"
)
if let bodyData = request.httpBody {
    let body = String(decoding: bodyData, as: UTF8.self)
    expect(body.contains("whisper-large-v3-turbo"), "model field in body")
    expect(body.contains("filename=\"audio.wav\""), "file part in body")
    expect(!body.contains("name=\"language\""), "no language field (auto-detect)")
} else {
    expect(false, "httpBody exists")
}

print("GroqClient.makeChatRequest")
let chatRequest = GroqClient.makeChatRequest(text: "こんにちはテストです", apiKey: "test-key", model: "llama-3.3-70b-versatile")
expect(chatRequest.url?.absoluteString == "https://api.groq.com/openai/v1/chat/completions", "chat endpoint URL")
expect(chatRequest.value(forHTTPHeaderField: "Authorization") == "Bearer test-key", "chat auth header")
if let chatBodyData = chatRequest.httpBody, let chatBody = try? JSONSerialization.jsonObject(with: chatBodyData) as? [String: Any] {
    expect(chatBody["model"] as? String == "llama-3.3-70b-versatile", "chat model field")
    expect(chatBody["temperature"] as? Int == 0, "temperature 0")
    let messages = chatBody["messages"] as? [[String: Any]] ?? []
    expect(messages.count == 2, "system + user messages")
    expect(messages.first?["role"] as? String == "system", "system prompt first")
    expect((messages.last?["content"] as? String) == "こんにちはテストです", "transcript as user message")
} else {
    expect(false, "chat httpBody is valid JSON")
}

print("UtteranceBoundary（実測ログの並びを再生）")
// 2026-08-02 の caption-debug.log から採った実際の (時刻, 文字数) の並び。
// 「確定（時刻あり）→ 時刻0で振り出し」が本物の切り替わりで、確定そのものは切り替わりではない
func replayBoundaries(_ steps: [(Double, Int)]) -> [Int] {
    var previousText = ""
    var previousStart: Double = -1
    var boundaries: [Int] = []
    for (index, step) in steps.enumerated() {
        let text = String(repeating: "あ", count: step.1)
        if UtteranceBoundary.isNew(
            previousText: previousText,
            previousSegmentStart: previousStart,
            text: text,
            segmentStart: step.0
        ) {
            boundaries.append(index)
        }
        previousStart = step.0
        previousText = text
    }
    return boundaries
}

// 実測の境目その1: 85→86→87→86→(確定 1.02, 85)→(0, 1)
expect(
    replayBoundaries([(0, 85), (0, 86), (0, 87), (0, 86), (1.02, 85), (0, 1), (0, 2)]) == [5],
    "確定は切り替わりでなく、その次の時刻0が切り替わり"
)
// 実測の境目その2: 短い発話でも同じ形
expect(
    replayBoundaries([(0, 8), (0, 9), (22.08, 9), (0, 1), (0, 2)]) == [3],
    "短い発話でも確定の次だけを拾う"
)
// 実測の境目その3
expect(
    replayBoundaries([(0, 95), (0, 96), (25.98, 97), (0, 1)]) == [3],
    "確定で文字数が増えても切り替わりにしない"
)
// 喋っている途中の言い直しで多少縮んでも切り替わりにしない。
// 実測で起きた縮みは 26→25 / 53→48 / 68→66 の3か所で、いずれも数文字ぶん。
// （別々の場所で起きた縮みを1本に繋ぐと現実には無い急落になるので、実測どおり分けて確かめる）
expect(replayBoundaries([(0, 24), (0, 26), (0, 25), (0, 26)]).isEmpty, "言い直し 26→25 は切り替わりにしない")
expect(replayBoundaries([(0, 48), (0, 53), (0, 48), (0, 49)]).isEmpty, "言い直し 53→48 は切り替わりにしない")
expect(replayBoundaries([(0, 65), (0, 68), (0, 66), (0, 68)]).isEmpty, "言い直し 68→66 は切り替わりにしない")
// 時刻が一切取れない環境向けの保険: 半分以下に縮んだら切り替わり
expect(
    replayBoundaries([(0, 40), (0, 42), (0, 1), (0, 3)]) == [2],
    "時刻なしでも振り出しへの縮みは拾う"
)
expect(
    replayBoundaries([(0, 1), (0, 2), (0, 3)]).isEmpty,
    "喋り始めは切り替わりにしない"
)

print("TextJoin")
expect(TextJoin.concat("こんにちは。", "テストです。") == "こんにちは。テストです。", "日本語は詰めて繋ぐ")
expect(TextJoin.concat("Hello.", "How are you?") == "Hello. How are you?", "英語は空白で繋ぐ")
expect(TextJoin.concat("", "あとから") == "あとから", "左が空ならそのまま")
expect(TextJoin.concat("さきに", "") == "さきに", "右が空ならそのまま")
expect(TextJoin.concat("Hello ", "world") == "Hello world", "既に空白があれば足さない")
expect(TextJoin.concat("これは", "AIです") == "これはAIです", "日本語と英字の境目も詰める")

print("GroqClient.collapseAddedNewlines")
// 整形が勝手に段落分けすると、貼り付け先で「[Pasted text +5 lines]」と折りたたまれて中身が見えなくなる
expect(
    GroqClient.collapseAddedNewlines(cleaned: "こんにちは。\nテストです。", raw: "こんにちはテストです")
        == "こんにちは。テストです。",
    "日本語は詰めて1行に戻す"
)
expect(
    GroqClient.collapseAddedNewlines(cleaned: "Hello there.\nHow are you?", raw: "hello there how are you")
        == "Hello there. How are you?",
    "英語は空白で繋ぐ"
)
expect(
    GroqClient.collapseAddedNewlines(cleaned: "一行目。\n\n  \n二行目。", raw: "一行目二行目")
        == "一行目。二行目。",
    "空行と前後の空白は落とす"
)
expect(
    GroqClient.collapseAddedNewlines(cleaned: "変わらない。", raw: "変わらない") == "変わらない。",
    "改行が無ければそのまま"
)
// 元テキストに改行があるなら、その改行は話者の意図なので触らない
expect(
    GroqClient.collapseAddedNewlines(cleaned: "一行目\n二行目", raw: "一行目\n二行目") == "一行目\n二行目",
    "元から改行があるときは畳まない"
)
expect(
    GroqClient.cleanupSystemPrompt.contains("改行を追加しない"),
    "整形プロンプトが改行の追加を禁じている"
)

print("GroqClient.makeEditRequest")
let editRequest = GroqClient.makeEditRequest(
    selection: "牛乳を買う 卵 パン",
    instruction: "これをリストにして",
    apiKey: "test-key",
    model: "llama-3.3-70b-versatile"
)
expect(editRequest.url?.absoluteString == "https://api.groq.com/openai/v1/chat/completions", "edit endpoint URL")
expect(editRequest.value(forHTTPHeaderField: "Authorization") == "Bearer test-key", "edit auth header")
if let editBodyData = editRequest.httpBody, let editBody = try? JSONSerialization.jsonObject(with: editBodyData) as? [String: Any] {
    expect(editBody["model"] as? String == "llama-3.3-70b-versatile", "edit model field")
    expect(editBody["temperature"] as? Int == 0, "edit temperature 0")
    let messages = editBody["messages"] as? [[String: Any]] ?? []
    expect(messages.count == 2, "edit system + user messages")
    expect(messages.first?["role"] as? String == "system", "edit system prompt first")
    expect((messages.first?["content"] as? String)?.contains("テキスト編集エンジン") == true, "edit system prompt content")
    expect((messages.first?["content"] as? String)?.contains("同音異義語") == true, "edit prompt handles speech mis-recognition")
    expect((messages.first?["content"] as? String)?.contains("そのまま出力") == true, "edit prompt preserves text on nonsense instruction")
    let userContent = (messages.last?["content"] as? String) ?? ""
    expect(userContent.contains("【選択テキスト】"), "user message has selection section")
    expect(userContent.contains("牛乳を買う 卵 パン"), "user message contains selection")
    expect(userContent.contains("【編集指示】"), "user message has instruction section")
    expect(userContent.contains("これをリストにして"), "user message contains instruction")
} else {
    expect(false, "edit httpBody is valid JSON")
}

print("Config")
let defaultConfig = Config.default
expect(defaultConfig.model == "whisper-large-v3-turbo", "default model")
expect(HotKeySpec.parse(defaultConfig.hotkey_toggle) != nil, "default toggle hotkey parseable")
expect(HotKeySpec.parse(defaultConfig.hotkey_paste_last) != nil, "default paste-last hotkey parseable")
expect(HotKeySpec.parse(defaultConfig.hotkey_edit) != nil, "default edit hotkey parseable")
expect(defaultConfig.cleanup_enabled == true, "cleanup enabled by default")
expect(defaultConfig.cleanup_model == "llama-3.3-70b-versatile", "default cleanup model")
expect(defaultConfig.hud_enabled == true, "hud on by default")
expect(defaultConfig.live_caption_enabled == true, "live caption on by default")
expect(defaultConfig.live_caption_locale == "ja-JP", "default caption locale")
expect(defaultConfig.duplicatedHotkey == nil, "default hotkeys do not collide")

// 同じキーを2つの機能に割り当てたら設定画面で弾く
var collided = Config.default
collided.hotkey_edit = collided.hotkey_toggle
expect(collided.duplicatedHotkey == "⌘/", "duplicate hotkey detected")
var reordered = Config.default
reordered.hotkey_paste_last = "cmd+ctrl+v"
expect(reordered.duplicatedHotkey == nil, "same combo written differently is not a false positive")
reordered.hotkey_edit = "cmd+ctrl+v"
expect(reordered.duplicatedHotkey == "⌃⌘V", "duplicate detected across different spellings")

// 旧バージョンのconfig（cleanup系キーなし）を読んでもAPIキーが消えない
let legacyJSON = """
{"groq_api_key":"legacy-key","model":"whisper-large-v3-turbo","hotkey_toggle":"option+space","hotkey_paste_last":"ctrl+cmd+v"}
"""
if let legacy = try? JSONDecoder().decode(Config.self, from: Data(legacyJSON.utf8)) {
    expect(legacy.groq_api_key == "legacy-key", "legacy config keeps api key")
    expect(legacy.cleanup_enabled == true, "legacy config gets cleanup default")
    expect(legacy.cleanup_model == "llama-3.3-70b-versatile", "legacy config gets cleanup model default")
    expect(legacy.hotkey_edit == "ctrl+slash", "legacy config gets edit hotkey default")
    expect(legacy.hotkey_toggle == "option+space", "legacy config keeps its own toggle hotkey")
    expect(legacy.hud_enabled == true, "legacy config gets hud default")
    expect(legacy.live_caption_enabled == true, "legacy config gets live caption default")
    expect(legacy.live_caption_locale == "ja-JP", "legacy config gets caption locale default")
} else {
    expect(false, "legacy config decodes")
}

print("")
print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
