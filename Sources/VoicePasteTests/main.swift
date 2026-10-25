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
let chatRequest = GroqClient.makeChatRequest(text: "こんにちはテストです", apiKey: "test-key", model: "qwen/qwen3.8-27b")
expect(chatRequest.url?.absoluteString == "https://api.groq.com/openai/v1/chat/completions", "chat endpoint URL")
expect(chatRequest.value(forHTTPHeaderField: "Authorization") == "Bearer test-key", "chat auth header")
if let chatBodyData = chatRequest.httpBody, let chatBody = try? JSONSerialization.jsonObject(with: chatBodyData) as? [String: Any] {
    expect(chatBody["model"] as? String == "qwen/qwen3.8-27b", "chat model field")
    expect(chatBody["temperature"] as? Int == 0, "temperature 0")
    let messages = chatBody["messages"] as? [[String: Any]] ?? []
    expect(messages.count == 2, "system + user messages")
    expect(messages.first?["role"] as? String == "system", "system prompt first")
    expect((messages.last?["content"] as? String) == "こんにちはテストです", "transcript as user message")
} else {
    expect(false, "chat httpBody is valid JSON")
}

print("GroqClient 出力上限と思考の設定（出力トークン／分の 429 対策）")
// 上限を付けないと Groq は既定の 2048 を要求とみなし、qwen の出力トークン／分の上限 1000 を超えるとして 429 で断る（2026-09-09〜）
expect(GroqClient.outputTokenBudget(inputCharacters: 0) == 32, "空でも 32 トークンの余裕")
expect(GroqClient.outputTokenBudget(inputCharacters: 149) == 210, "149字 → 149×1.2+32 = 210（実測の出力 61 トークンの3倍）")
expect(GroqClient.outputTokenBudget(inputCharacters: 5000) == GroqClient.outputTokenCap, "長すぎる入力は 1000 で頭打ち（超えると要求の時点で断られる）")
expect(GroqClient.outputTokenBudget(inputCharacters: 100, growth: 2.0) == 232, "伸び率を上げられる（編集用）")
func chatJSON(_ request: URLRequest) -> [String: Any] {
    request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
}
let qwenBody = chatJSON(GroqClient.makeChatRequest(text: String(repeating: "あ", count: 149), apiKey: "k", model: "qwen/qwen3.8-27b"))
expect(qwenBody["max_completion_tokens"] as? Int == 210, "整形リクエストに入力長ぶんの出力上限が付く")
expect(qwenBody["reasoning_effort"] as? String == "none", "qwen 系は思考を切る（<think> の混入と、思考で上限を食い切る事故の防止）")
let ossBody = chatJSON(GroqClient.makeChatRequest(text: "hello", apiKey: "k", model: "openai/gpt-oss-20b"))
expect(ossBody["reasoning_effort"] == nil, "gpt-oss 系には reasoning_effort を付けない（none を受け付けない）")
expect(ossBody["max_completion_tokens"] as? Int == 38, "5字 → 5×1.2+32 = 38")
let editBody = chatJSON(GroqClient.makeEditRequest(
    selection: String(repeating: "あ", count: 100), instruction: String(repeating: "い", count: 10),
    apiKey: "k", model: "qwen/qwen3.8-27b"
))
expect(editBody["max_completion_tokens"] as? Int == 252, "編集は（選択＋指示）×2.0+32 = 252（翻訳・追記で伸びる）")

print("GroqClient 予備モデルへの切り替え（待たずに別モデルで1回）")
expect(GroqClient.chatModelsToTry(primary: "qwen/qwen3.8-27b") == ["qwen/qwen3.8-27b", "qwen/qwen3.6-27b"], "既定: 3.8 → 予備 3.6")
expect(GroqClient.chatModelsToTry(primary: "qwen/qwen3.6-27b") == ["qwen/qwen3.6-27b", "qwen/qwen3.8-27b"], "設定が 3.6 なら予備は 3.8（同じモデルを2回試さない）")
expect(GroqClient.chatModelsToTry(primary: "openai/gpt-oss-120b") == ["openai/gpt-oss-120b", "qwen/qwen3.6-27b", "qwen/qwen3.8-27b"], "設定が別のモデルでも予備2つが続く")
let outputLimitBody = #"{"error":{"message":"Request too large for model `qwen/qwen3.8-27b` in organization `org_x` service tier `on_demand` on output tokens per minute (OTPM): Limit 1000, Requested 2048."}}"#
expect(GroqClient.isOutputLimit(statusCode: 429, body: outputLimitBody), "実測の 429 本文を出力上限として認識")
expect(!GroqClient.isOutputLimit(statusCode: 429, body: "Rate limit reached for requests"), "回数のレート制限は出力上限ではない")
expect(!GroqClient.isOutputLimit(statusCode: 500, body: outputLimitBody), "429 以外は出力上限ではない")
expect(!GroqClient.shouldStopFallback(GroqClient.ClientError.apiError(statusCode: 429, body: outputLimitBody)), "出力上限（429）→ 予備へ切り替える")
expect(!GroqClient.shouldStopFallback(GroqClient.ClientError.apiError(statusCode: 500, body: "")), "一時エラー（5xx）→ 予備へ切り替える")
expect(!GroqClient.shouldStopFallback(GroqClient.ClientError.apiError(statusCode: 404, body: "model_not_found")), "モデル廃止（404）→ 予備へ切り替える")
expect(GroqClient.shouldStopFallback(GroqClient.ClientError.apiError(statusCode: 401, body: "")), "キー不正（401）→ 切り替えても直らないので止める")
expect(GroqClient.shouldStopFallback(GroqClient.ClientError.truncated(model: "qwen/qwen3.8-27b")), "途中で切れた → 予備も同じ上限で切れるので止める")
expect(GroqClient.shouldStopFallback(CancellationError()), "Esc（取り消し）→ 切り替えない")
expect(!GroqClient.shouldStopFallback(URLError(.notConnectedToInternet)), "通信断 → 予備を試す（すぐ失敗して抜ける）")
expect(GroqClient.shortReason(GroqClient.ClientError.apiError(statusCode: 429, body: outputLimitBody)) == "HTTP 429（出力トークンの上限）", "診断ログ用の短い理由")

print("GroqClient.parseChat（応答の取り出し）")
func chatResponse(content: String?, finish: String) -> Data {
    let message: [String: Any] = content.map { ["content": $0] } ?? [:]
    let json: [String: Any] = ["choices": [["message": message, "finish_reason": finish]]]
    return try! JSONSerialization.data(withJSONObject: json)
}
expect((try? GroqClient.parseChat(chatResponse(content: "整形しました。", finish: "stop"), model: "m")) == "整形しました。", "普通の応答は本文を返す")
expect((try? GroqClient.parseChat(chatResponse(content: "<think>考え中</think>本文", finish: "stop"), model: "m")) == "本文", "<think> は取り除く")
do {
    _ = try GroqClient.parseChat(chatResponse(content: "途中まで", finish: "length"), model: "m")
    expect(false, "finish_reason=length は失敗にする")
} catch GroqClient.ClientError.truncated(let model) {
    expect(model == "m", "途中で切れた応答は貼らない（末尾が消えるため）")
} catch {
    expect(false, "length は truncated として投げる（実際: \(error)）")
}
expect((try? GroqClient.parseChat(chatResponse(content: "", finish: "stop"), model: "m")) == nil, "本文が空なら失敗（予備で取り直す）")
expect((try? GroqClient.parseChat(chatResponse(content: nil, finish: "stop"), model: "m")) == nil, "content 無しも失敗")

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
expect(
    GroqClient.cleanupSystemPrompt.contains("意味を持つ数字"),
    "整形プロンプトが、化けたつなぎ言葉を消しつつ本物の数字は守るよう指示している"
)

print("GroqClient.transcriptionHint")
// 発話先頭の「えーっと」が別語に化けるのを防ぐヒント（実測・2026-08-10）。
// language=ja では直らず、このヒントで直った
expect(
    GroqClient.transcriptionHint.contains("えーっと"),
    "認識ヒントがつなぎ言葉の例を含む"
)
if let hintBody = GroqClient.makeRequest(
    wav: Data(), apiKey: "test-key", model: "whisper-large-v3-turbo", boundary: "B"
).httpBody, let hintText = String(data: hintBody, encoding: .utf8) {
    expect(hintText.contains("name=\"prompt\""), "認識リクエストにヒントが載っている")
    expect(hintText.contains(GroqClient.transcriptionHint), "ヒントの中身が入っている")
    expect(!hintText.contains("name=\"language\""), "言語は固定しない（英語の自動判定を残す）")
}

print("CleanupGuard")
// 実際に起きた壊れ方: 整形するはずが質問に答えてしまい、AIの回答が貼られた（2026-08-10）
expect(
    !CleanupGuard.accept(
        raw: "この構成のメリットとデメリットを箇条書きで出して",
        cleaned: "この構成のメリットとデメリットは、以下の通りです。メリット：整形されたテキストが出力されるので、読みやすくなり、理解もしやすくなります。デメリット：フィラーが除去されるため、話者のニュアンスや感情が失われる可能性があります。"
    ),
    "整形が質問に答えてしまった結果は弾く"
)
expect(
    CleanupGuard.accept(
        raw: "えーとこちらは今どういう状況ですかかいつまんで説明してください",
        cleaned: "こちらは今どういう状況ですか、かいつまんで説明してください。"
    ),
    "句読点を足してつなぎ言葉を消しただけなら通す"
)
expect(
    CleanupGuard.accept(raw: "8これ今どうなってるか教えて", cleaned: "これは今どうなってるか教えて。"),
    "化けたつなぎ言葉を落としただけなら通す"
)
expect(
    CleanupGuard.accept(
        raw: "8 明日の会議は10時からで参加者は8人です",
        cleaned: "明日の会議は10時からで、参加者は8人です。"
    ),
    "本物の数字を残したまま頭の余計な数字を落とすのは通す"
)
// つなぎ言葉だらけの発話。中身がほとんど消えても、残った文字は元テキスト由来なので通す
expect(
    CleanupGuard.accept(raw: "えーっとえーっとえーっとはい", cleaned: "はい。"),
    "つなぎ言葉だけが大量に消えるのは通す"
)
expect(
    !CleanupGuard.accept(raw: "現状どうなってる", cleaned: "現状については私には分かりません。"),
    "質問に答えた短い文も弾く"
)
expect(!CleanupGuard.accept(raw: "はい", cleaned: ""), "中身のある発話が空になったら弾く")
expect(CleanupGuard.accept(raw: "", cleaned: ""), "空は空のまま通す")
expect(
    CleanupGuard.longestCommonSubsequenceLength(Array("あいうえお"), Array("あうお")) == 3,
    "共有している並びの長さを数えられる"
)
expect(
    CleanupGuard.core(of: "こんにちは、世界。").count == 7,
    "判定では句読点を数に入れない"
)

print("GroqClient.makeEditRequest")
let editRequest = GroqClient.makeEditRequest(
    selection: "牛乳を買う 卵 パン",
    instruction: "これをリストにして",
    apiKey: "test-key",
    model: "qwen/qwen3.8-27b"
)
expect(editRequest.url?.absoluteString == "https://api.groq.com/openai/v1/chat/completions", "edit endpoint URL")
expect(editRequest.value(forHTTPHeaderField: "Authorization") == "Bearer test-key", "edit auth header")
if let editBodyData = editRequest.httpBody, let editBody = try? JSONSerialization.jsonObject(with: editBodyData) as? [String: Any] {
    expect(editBody["model"] as? String == "qwen/qwen3.8-27b", "edit model field")
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

print("GroqClient 再試行の判定")
expect(GroqClient.maxAttempts == 3, "送る回数は最大3回")
expect(GroqClient.isRetryable(statusCode: 500), "HTTP 500（Groq側の一時エラー）は送り直す")
expect(GroqClient.isRetryable(statusCode: 503), "HTTP 503 は送り直す")
expect(GroqClient.isRetryable(statusCode: 429), "HTTP 429（レート制限）は送り直す")
expect(!GroqClient.isRetryable(statusCode: 404), "HTTP 404（モデル無し）は送り直さない")
expect(!GroqClient.isRetryable(statusCode: 401), "HTTP 401（キー不正）は送り直さない")
expect(!GroqClient.isRetryable(statusCode: 400), "HTTP 400（リクエスト不正）は送り直さない")
expect(!GroqClient.isRetryable(statusCode: 200), "HTTP 200 は送り直さない")
expect(GroqClient.retryDelay(afterAttempt: 1) == 0.5, "1回目の失敗のあとは0.5秒待つ")
expect(GroqClient.retryDelay(afterAttempt: 2) == 1.0, "2回目の失敗のあとは1秒待つ")
let transient = GroqClient.ClientError.apiError(statusCode: 500, body: "{\"error\":{\"message\":\"Internal Server Error\"}}")
expect(transient.errorDescription?.contains("一時的なエラー") == true, "5xx の文言に一時的なエラーの可能性を添える")
let retired = GroqClient.ClientError.apiError(statusCode: 404, body: "{\"error\":{\"code\":\"model_not_found\"}}")
expect(retired.errorDescription?.contains("廃止") == true, "model_not_found の文言にモデル廃止の可能性を添える")
expect(retired.errorDescription?.contains("一時的なエラー") == false, "404 に一時的なエラーの文言は付けない")

print("GroqClient.stripThinking（思考文の除去）")
expect(GroqClient.stripThinking("<think>\nまず句読点を…\n</think>\n現在のタスク管理をお願いします。") == "現在のタスク管理をお願いします。",
       "先頭の <think>…</think> を取り除く")
expect(GroqClient.stripThinking("現在のタスク管理をお願いします。") == "現在のタスク管理をお願いします。",
       "思考文が無ければそのまま")
expect(GroqClient.stripThinking("<think>a</think>本文<think>b</think>") == "本文", "複数あっても全部取り除く")
expect(GroqClient.stripThinking("<think>途中で切れた") == "<think>途中で切れた", "閉じタグが無ければ触らない")

print("InputDeviceSelection（録音に使うマイクの決め方）")
let builtInMic = InputDeviceInfo(uid: "BuiltInMicrophoneDevice", name: "MacBook Airのマイク", isBuiltIn: true, isSystemDefault: false)
let airPods = InputDeviceInfo(uid: "AIRPODS-UID", name: "AirPods Pro", isBuiltIn: false, isSystemDefault: true)
let withAirPods = [builtInMic, airPods]
expect(InputDeviceSelection.resolve(setting: "builtin", devices: withAirPods).device == builtInMic,
       "既定(builtin): AirPodsがmacOSの既定入力でも内蔵マイクを使う")
expect(InputDeviceSelection.resolve(setting: "builtin", devices: withAirPods).note == nil, "設定どおり選べたときは理由なし")
expect(InputDeviceSelection.resolve(setting: "", devices: withAirPods).device == builtInMic, "空の設定は既定(内蔵)と同じ")
expect(InputDeviceSelection.resolve(setting: "system", devices: withAirPods).device == airPods, "system: macOSの既定入力(AirPods)に従う")
expect(InputDeviceSelection.resolve(setting: "AIRPODS-UID", devices: withAirPods).device == airPods, "UID指定: つながっていればその機器")
let withoutAirPods = [InputDeviceInfo(uid: "BuiltInMicrophoneDevice", name: "MacBook Airのマイク", isBuiltIn: true, isSystemDefault: true)]
let missing = InputDeviceSelection.resolve(setting: "AIRPODS-UID", devices: withoutAirPods)
expect(missing.device?.isBuiltIn == true, "UID指定の機器が未接続なら内蔵マイクに戻す")
expect(missing.note?.contains("見つからない") == true, "戻したときは理由を添える")
let noBuiltIn = [InputDeviceInfo(uid: "USB-1", name: "USBマイク", isBuiltIn: false, isSystemDefault: true)]
let fallback = InputDeviceSelection.resolve(setting: "builtin", devices: noBuiltIn)
expect(fallback.device?.uid == "USB-1", "内蔵マイクが無い機種ではmacOSの既定入力を使う")
expect(fallback.note?.contains("内蔵マイクが見つからない") == true, "内蔵が無いときも理由を添える")
expect(InputDeviceSelection.resolve(setting: "builtin", devices: []).device == nil, "機器が1つも無ければ指定なし（エンジン任せ）")

print("Config")
let defaultConfig = Config.default
expect(defaultConfig.model == "whisper-large-v3-turbo", "default model")
expect(HotKeySpec.parse(defaultConfig.hotkey_toggle) != nil, "default toggle hotkey parseable")
expect(HotKeySpec.parse(defaultConfig.hotkey_paste_last) != nil, "default paste-last hotkey parseable")
expect(HotKeySpec.parse(defaultConfig.hotkey_edit) != nil, "default edit hotkey parseable")
expect(defaultConfig.cleanup_enabled == true, "cleanup enabled by default")
expect(defaultConfig.cleanup_model == "qwen/qwen3.8-27b", "default cleanup model")
expect(defaultConfig.hud_enabled == true, "hud on by default")
expect(defaultConfig.live_caption_enabled == true, "live caption on by default")
expect(defaultConfig.live_caption_locale == "ja-JP", "default caption locale")
// 既定はクリップボードを使わない。使うとクリップボード履歴アプリに音声入力の結果が積まれてしまう
expect(defaultConfig.paste_via_clipboard == false, "貼り付けは既定でクリップボードを使わない")
expect(defaultConfig.input_device == "builtin", "録音に使うマイクは既定でMacの内蔵")
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

// 廃止された整形モデルが config.json に残っていたら、読み込み時に既定へ置き換える
let retiredJSON = """
{"groq_api_key":"k","cleanup_model":"llama-3.3-70b-versatile"}
"""
if let migrated = try? JSONDecoder().decode(Config.self, from: Data(retiredJSON.utf8)) {
    expect(migrated.cleanup_model == Config.default.cleanup_model, "廃止モデル llama-3.3-70b-versatile は既定へ置き換える")
} else {
    expect(false, "retired-model config decodes")
}
let customJSON = """
{"groq_api_key":"k","cleanup_model":"openai/gpt-oss-120b"}
"""
if let custom = try? JSONDecoder().decode(Config.self, from: Data(customJSON.utf8)) {
    expect(custom.cleanup_model == "openai/gpt-oss-120b", "廃止でないモデル名はそのまま残す")
} else {
    expect(false, "custom-model config decodes")
}

// 旧バージョンのconfig（cleanup系キーなし）を読んでもAPIキーが消えない
let legacyJSON = """
{"groq_api_key":"legacy-key","model":"whisper-large-v3-turbo","hotkey_toggle":"option+space","hotkey_paste_last":"ctrl+cmd+v"}
"""
if let legacy = try? JSONDecoder().decode(Config.self, from: Data(legacyJSON.utf8)) {
    expect(legacy.groq_api_key == "legacy-key", "legacy config keeps api key")
    expect(legacy.cleanup_enabled == true, "legacy config gets cleanup default")
    expect(legacy.cleanup_model == "qwen/qwen3.8-27b", "legacy config gets cleanup model default")
    expect(legacy.hotkey_edit == "ctrl+slash", "legacy config gets edit hotkey default")
    expect(legacy.hotkey_toggle == "option+space", "legacy config keeps its own toggle hotkey")
    expect(legacy.hud_enabled == true, "legacy config gets hud default")
    expect(legacy.live_caption_enabled == true, "legacy config gets live caption default")
    expect(legacy.live_caption_locale == "ja-JP", "legacy config gets caption locale default")
    expect(legacy.paste_via_clipboard == false, "既存のconfigも読み直すとクリップボードを使わなくなる")
    expect(legacy.input_device == "builtin", "古いconfigにもマイク設定の既定（内蔵）が入る")
} else {
    expect(false, "legacy config decodes")
}

print("直接入力の分割（クリップボードを使わない貼り付け）")
do {
    // つなぎ直したら元に戻る、が最低条件
    for text in [
        "",
        "短い",
        "音声入力した長めの文章をそのままカーソル位置へ入れる。句読点も含めて崩れないこと。",
        String(repeating: "あ", count: 200),
        "絵文字🙂と結合文字👨‍👩‍👧‍👦が混ざる場合",
        "English mixed with 日本語 and numbers 12345",
    ] {
        expect(TypedText.chunks(of: text).joined() == text, "つなぎ直すと元に戻る: \(text.prefix(12))")
    }
    expect(TypedText.chunks(of: "").isEmpty, "空文字は送るものがない")

    // 上限を超えない。超えると相手に届かない文字が出る
    let long = String(repeating: "あ", count: 105)
    let chunks = TypedText.chunks(of: long, limit: 20)
    expect(chunks.allSatisfy { $0.utf16.count <= 20 }, "どの塊も上限を超えない")
    expect(chunks.count == 6, "105文字は20区切りで6つ")

    // 書記素の途中で切ると化けるので、切ってはいけない
    let family = "👨‍👩‍👧‍👦"  // UTF-16で11。単独でも上限を超えるが割ってはいけない
    expect(TypedText.chunks(of: family, limit: 4) == [family], "上限を超える1文字でも割らない")
    let emojis = String(repeating: "🙂", count: 30)  // 1つあたりUTF-16で2
    expect(
        TypedText.chunks(of: emojis, limit: 5).allSatisfy { $0.utf16.count % 2 == 0 },
        "サロゲートペアを割らない"
    )
    expect(TypedText.chunks(of: emojis, limit: 5).joined() == emojis, "絵文字だけでも元に戻る")
}

print("ログイン時の自動起動（登録内容）")
do {
    let dictionary = LoginItem.plistDictionary(
        executablePath: "/tmp/VoicePaste.app/Contents/MacOS/VoicePaste",
        logPath: "/tmp/VoicePaste.log"
    )
    expect(dictionary["Label"] as? String == LoginItem.label, "label")
    expect(
        dictionary["ProgramArguments"] as? [String] == ["/tmp/VoicePaste.app/Contents/MacOS/VoicePaste"],
        "起動するのはバンドル内のバイナリ"
    )
    expect(dictionary["RunAtLoad"] as? Bool == true, "ログイン時に起動する")
    // 正常終了（メニューから終了）では立ち上がってこない設定になっているか
    expect(
        (dictionary["KeepAlive"] as? [String: Bool])?["SuccessfulExit"] == false,
        "異常終了した時だけ起動し直す"
    )
    expect(dictionary["StandardErrorPath"] as? String == "/tmp/VoicePaste.log", "エラー出力先")

    // 書き出して読み直しても壊れない。パスに & や空白や日本語が入っていてもXMLとして成立する
    for path in [
        "/Users/me/Apps/VoicePaste.app/Contents/MacOS/VoicePaste",
        "/Users/me/R&D projects/音声/VoicePaste.app/Contents/MacOS/VoicePaste",
        "/Users/me/<weird>/VoicePaste.app/Contents/MacOS/VoicePaste",
    ] {
        if let data = try? LoginItem.plistData(executablePath: path, logPath: "/tmp/VoicePaste.log") {
            expect(
                LoginItem.registeredExecutablePath(plistData: data) == path,
                "書き出して読み直せる: \(path)"
            )
        } else {
            expect(false, "書き出せる: \(path)")
        }
    }

    // 壊れたファイルを「登録済み」と誤判定しない
    expect(
        LoginItem.registeredExecutablePath(plistData: Data("これはplistではない".utf8)) == nil,
        "plistでないファイルは未登録として扱う"
    )
    if let empty = try? PropertyListSerialization.data(
        fromPropertyList: [String: Any](), format: .xml, options: 0)
    {
        expect(
            LoginItem.registeredExecutablePath(plistData: empty) == nil,
            "起動対象の書かれていないplistは未登録として扱う"
        )
    }
}

print("SpeechPresence（声が入っていたかの判定・合成波形で再現）")
// 乱数は結果が毎回同じになるよう自前で持つ（線形合同法 + Box-Muller）
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
func noise(seconds: Double, sigma: Float, seed: UInt64 = 12345) -> [Float] {
    var generator = TestNoise(state: seed)
    return (0..<Int(seconds * 16000)).map { _ in generator.gaussian(sigma) }
}
func tone(seconds: Double, amplitude: Float, hz: Double = 220) -> [Float] {
    (0..<Int(seconds * 16000)).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / 16000)) }
}
func mix(_ base: [Float], _ insert: [Float], at second: Double) -> [Float] {
    var out = base
    let start = Int(second * 16000)
    for (index, value) in insert.enumerated() where start + index < out.count {
        out[start + index] += value
    }
    return out
}

expect(!SpeechPresence.measure(samples: []).hasSpeech, "空 → 声なし")
expect(!SpeechPresence.measure(samples: [Float](repeating: 0, count: 24000)).hasSpeech, "完全な無音1.5秒 → 声なし")
expect(!SpeechPresence.measure(samples: noise(seconds: 1.0, sigma: 0.0005)).hasSpeech,
       "デジタル無音に近いゆらぎ（RMS 0.0005）→ 声なし（閾値の下限 0.002 が効く）")

// 実測に寄せた条件: 幻覚が出た録音は内蔵マイクでピーク 0.04 ＝ 部屋のノイズ RMS 0.01 程度
let room = noise(seconds: 1.5, sigma: 0.01)
let roomMeasure = SpeechPresence.measure(samples: room)
expect(!roomMeasure.hasSpeech, "部屋のノイズ1.5秒（RMS 0.01）だけ → 声なし")
expect(roomMeasure.noiseFloor > 0.008 && roomMeasure.noiseFloor < 0.012, "床はノイズの大きさになる（\(roomMeasure.noiseFloor)）")
expect(roomMeasure.longestRunSeconds == 0, "定常ノイズは床の1.5倍を超えるコマが無い")

// ホットキーを押す音: 30ms で減衰する衝撃を、録音の直後と停止の直前に1つずつ
var clicks = room
for start in [0.1, 1.3] {
    let click = (0..<480).map { i in Float(0.05 * exp(-Double(i) / 80)) * (i % 2 == 0 ? 1 : -1) }
    clicks = mix(clicks, click, at: start)
}
let clickMeasure = SpeechPresence.measure(samples: clicks)
expect(!clickMeasure.hasSpeech, "キーを押す音（30ms×2）→ 声なし")
expect(clickMeasure.longestRunSeconds <= 0.04, "キーの音は2コマ以内で消える（\(clickMeasure.longestRunSeconds)秒）")

expect(SpeechPresence.measure(samples: mix(room, tone(seconds: 0.12, amplitude: 0.03), at: 0.5)).hasSpeech,
       "小声の短い発話（0.12秒・床の2倍）→ 声あり")
expect(!SpeechPresence.measure(samples: mix(room, tone(seconds: 0.04, amplitude: 0.03), at: 0.5)).hasSpeech,
       "40msしか続かない音 → 声なし")
expect(SpeechPresence.measure(samples: mix(noise(seconds: 1.5, sigma: 0.003), tone(seconds: 0.3, amplitude: 0.012), at: 0.5)).hasSpeech,
       "静かな部屋（RMS 0.003）での小声（振幅0.012）→ 声あり")
expect(!SpeechPresence.measure(samples: mix(room, tone(seconds: 0.3, amplitude: 0.012), at: 0.5)).hasSpeech,
       "床（0.01）に埋もれた音（振幅0.012）→ 声なし（Whisperも聞き取れない領域）")
// 息がマイクにかかった音（0.4秒のノイズの盛り上がり）は声と区別できない。ここでは通して、幻覚句の照合に任せる
var breath = room
var breathNoise = TestNoise(state: 99)
for index in Int(0.4 * 16000)..<Int(0.8 * 16000) { breath[index] += breathNoise.gaussian(0.035) }
expect(SpeechPresence.measure(samples: breath).hasSpeech, "息（0.4秒続く）は声として通す（区別できないので Whisper 側に任せる）")
// 録音全体が声で埋まっていて静かな部分が無い（床そのものが高い）→ 無音ではないので送る
expect(SpeechPresence.measure(samples: tone(seconds: 0.3, amplitude: 0.05)).hasSpeech,
       "静かな部分の無い短い録音（全体が音）→ 声あり")
let summary = roomMeasure.summary
expect(summary.contains("声のある区間") && summary.contains("床0.0"), "診断ログ用の1行に判定材料が入る: \(summary)")

print("KnownHallucinations（無音から作られる決まり文句の照合）")
expect(KnownHallucinations.isKnownPhrase("ご視聴ありがとうございました。"), "実測の幻覚句（句点付き）")
expect(KnownHallucinations.isKnownPhrase(" ご視聴ありがとうございました "), "前後の空白があっても一致")
expect(KnownHallucinations.isKnownPhrase("Thank you for watching!"), "英語の締めの挨拶（大文字・記号）")
expect(!KnownHallucinations.isKnownPhrase("ご視聴ありがとうございました。今日は設定の話です。"), "本文の一部に含まれるだけなら捨てない")
expect(!KnownHallucinations.isKnownPhrase("ありがとうございました。"), "普通の「ありがとうございました」は捨てない")
expect(!KnownHallucinations.isKnownPhrase("はい。"), "短い相槌は捨てない（本物と区別できない）")
expect(!KnownHallucinations.isKnownPhrase("Thank you."), "普通の Thank you は捨てない")
expect(!KnownHallucinations.isKnownPhrase(""), "空は幻覚句ではない（無音として別に扱う）")

print("")
print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
