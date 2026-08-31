import Foundation

public struct Config: Codable {
    public var groq_api_key: String
    public var model: String
    public var hotkey_toggle: String
    public var hotkey_paste_last: String
    /// 編集モード: テキスト選択中に押す→音声指示→選択部分を書き換え
    public var hotkey_edit: String
    /// 認識後にLLMで句読点補正・フィラー除去を行うか
    public var cleanup_enabled: Bool
    public var cleanup_model: String
    /// 録音中に画面下へポップアップ（状態・音量メーター・字幕）を出すか
    public var hud_enabled: Bool
    /// ポップアップに喋った内容をリアルタイム表示するか（macOS内蔵のオンデバイス認識を使う）
    public var live_caption_enabled: Bool
    /// リアルタイム表示に使う言語。確定テキストはGroq Whisperの自動判定なのでここは表示専用
    public var live_caption_locale: String
    /// 貼り付けにクリップボードを使うか。
    /// 既定の false では文字を直接キー入力として送るので、クリップボードとその履歴アプリを汚さない。
    /// 文字が化ける・取りこぼすアプリがあった場合の逃げ道として true にできる
    public var paste_via_clipboard: Bool

    public init(
        groq_api_key: String,
        model: String,
        hotkey_toggle: String,
        hotkey_paste_last: String,
        hotkey_edit: String,
        cleanup_enabled: Bool,
        cleanup_model: String,
        hud_enabled: Bool,
        live_caption_enabled: Bool,
        live_caption_locale: String,
        paste_via_clipboard: Bool
    ) {
        self.groq_api_key = groq_api_key
        self.model = model
        self.hotkey_toggle = hotkey_toggle
        self.hotkey_paste_last = hotkey_paste_last
        self.hotkey_edit = hotkey_edit
        self.cleanup_enabled = cleanup_enabled
        self.cleanup_model = cleanup_model
        self.hud_enabled = hud_enabled
        self.live_caption_enabled = live_caption_enabled
        self.live_caption_locale = live_caption_locale
        self.paste_via_clipboard = paste_via_clipboard
    }

    /// 古い config.json に無いキーはデフォルト値で埋める（後方互換）
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let def = Config.default
        groq_api_key = try container.decodeIfPresent(String.self, forKey: .groq_api_key) ?? def.groq_api_key
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? def.model
        hotkey_toggle = try container.decodeIfPresent(String.self, forKey: .hotkey_toggle) ?? def.hotkey_toggle
        hotkey_paste_last = try container.decodeIfPresent(String.self, forKey: .hotkey_paste_last) ?? def.hotkey_paste_last
        hotkey_edit = try container.decodeIfPresent(String.self, forKey: .hotkey_edit) ?? def.hotkey_edit
        cleanup_enabled = try container.decodeIfPresent(Bool.self, forKey: .cleanup_enabled) ?? def.cleanup_enabled
        let storedCleanupModel = try container.decodeIfPresent(String.self, forKey: .cleanup_model) ?? def.cleanup_model
        cleanup_model = Config.retiredCleanupModels.contains(storedCleanupModel) ? def.cleanup_model : storedCleanupModel
        hud_enabled = try container.decodeIfPresent(Bool.self, forKey: .hud_enabled) ?? def.hud_enabled
        live_caption_enabled = try container.decodeIfPresent(Bool.self, forKey: .live_caption_enabled) ?? def.live_caption_enabled
        live_caption_locale = try container.decodeIfPresent(String.self, forKey: .live_caption_locale) ?? def.live_caption_locale
        paste_via_clipboard = try container.decodeIfPresent(Bool.self, forKey: .paste_via_clipboard) ?? def.paste_via_clipboard
    }

    /// Groqから廃止された整形モデル。config.json に残っていたら読み込み時に既定へ置き換える。
    /// `llama-3.3-70b-versatile` は 2026-08 に廃止され（HTTP 404 model_not_found）、
    /// 気づかないまま9日間、整形が黙って失敗して生テキストがそのまま貼られていた（2026-08-29 発見）
    public static let retiredCleanupModels: Set<String> = ["llama-3.3-70b-versatile"]

    /// 整形モデルの既定は `qwen/qwen3.8-27b`。
    /// 2026-08-29 の実測（同じ整形プロンプト・日英3サンプル）で、0.4〜0.5秒・出力に思考文が混ざらず・
    /// 句読点とフィラー除去が正しかった。`openai/gpt-oss-120b` は結果は良いが1秒超、
    /// `openai/gpt-oss-20b` は空応答が出た、`qwen/qwen3.6-27b` は `<think>` が本文に混ざった
    public static let `default` = Config(
        groq_api_key: "",
        model: "whisper-large-v3-turbo",
        hotkey_toggle: "cmd+slash",
        hotkey_paste_last: "ctrl+cmd+v",
        hotkey_edit: "ctrl+slash",
        cleanup_enabled: true,
        cleanup_model: "qwen/qwen3.8-27b",
        hud_enabled: true,
        live_caption_enabled: true,
        live_caption_locale: "ja-JP",
        paste_via_clipboard: false
    )

    public static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/voicepaste/config.json")
    }

    public static func load() -> Config {
        if let data = try? Data(contentsOf: configURL),
           let config = try? JSONDecoder().decode(Config.self, from: data) {
            return config
        }
        let config = Config.default
        try? save(config)
        return config
    }

    public static func save(_ config: Config) throws {
        let dir = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: configURL)
    }

    /// APIキーの解決順: config.json → 環境変数 GROQ_API_KEY
    public var resolvedAPIKey: String? {
        if !groq_api_key.isEmpty { return groq_api_key }
        if let env = ProcessInfo.processInfo.environment["GROQ_API_KEY"], !env.isEmpty { return env }
        return nil
    }

    /// 同じキーの組み合わせを2つ以上の機能に割り当てていないか。重複していたらその表示名を返す
    public var duplicatedHotkey: String? {
        let specs = [hotkey_toggle, hotkey_paste_last, hotkey_edit].compactMap { HotKeySpec.parse($0) }
        guard specs.count == 3 else { return nil }
        for i in 0..<specs.count {
            for j in (i + 1)..<specs.count where specs[i] == specs[j] {
                return specs[i].symbolString
            }
        }
        return nil
    }
}
