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
        live_caption_locale: String
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
        cleanup_model = try container.decodeIfPresent(String.self, forKey: .cleanup_model) ?? def.cleanup_model
        hud_enabled = try container.decodeIfPresent(Bool.self, forKey: .hud_enabled) ?? def.hud_enabled
        live_caption_enabled = try container.decodeIfPresent(Bool.self, forKey: .live_caption_enabled) ?? def.live_caption_enabled
        live_caption_locale = try container.decodeIfPresent(String.self, forKey: .live_caption_locale) ?? def.live_caption_locale
    }

    public static let `default` = Config(
        groq_api_key: "",
        model: "whisper-large-v3-turbo",
        hotkey_toggle: "cmd+slash",
        hotkey_paste_last: "ctrl+cmd+v",
        hotkey_edit: "ctrl+slash",
        cleanup_enabled: true,
        cleanup_model: "llama-3.3-70b-versatile",
        hud_enabled: true,
        live_caption_enabled: true,
        live_caption_locale: "ja-JP"
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
