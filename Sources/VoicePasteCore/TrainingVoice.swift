import Foundation

/// 「学習用に残す」: 音声入力した声を、声のモデル（Style-Bert-VITS2）の学習に使えるように1回ずつ保存する。
///
/// Groq へ送る音声は 16kHz に落としてあるが、学習には 44.1kHz 以上が要るので、
/// マイクの元の音質のサンプルを別に受け取って書く。
/// 仕事の話を残さないよう、メニューバーで切り替える（既定はオフ。2026-10-25）
public enum TrainingVoice {
    /// 保存先。音声は設定ではないので ~/.config ではなく Application Support に置く
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoicePaste/training-voice")
    }

    /// 残すかどうか。enabled は録音を止めた時点の設定（話しながらポップアップのボタンでオフにした回は残さない）
    public static func shouldKeep(enabled: Bool, isDictation: Bool, hasSpeech: Bool,
                                  transcript: String, isHallucination: Bool) -> Bool {
        enabled && isDictation && hasSpeech && !isHallucination
            && !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 1回ぶんの記録（json に書く中身）。文字起こしは学習のときに手元でもう一度かけて、食い違う回は使わない
    public struct Record: Codable, Equatable {
        public var recordedAt: String
        /// Groq の生の文字起こし（整形の前）
        public var raw: String
        /// 貼り付けた文（整形の後）
        public var cleaned: String
        public var mic: String?
        public var seconds: Double
        public var sampleRate: Int
        public var transcribeModel: String

        enum CodingKeys: String, CodingKey {
            case recordedAt = "recorded_at"
            case raw, cleaned, mic, seconds
            case sampleRate = "sample_rate"
            case transcribeModel = "transcribe_model"
        }

        public init(recordedAt: Date, raw: String, cleaned: String, mic: String?,
                    seconds: Double, sampleRate: Int, transcribeModel: String) {
            self.recordedAt = TrainingVoice.isoFormatter.string(from: recordedAt)
            self.raw = raw
            self.cleaned = cleaned
            self.mic = mic
            self.seconds = seconds
            self.sampleRate = sampleRate
            self.transcribeModel = transcribeModel
        }
    }

    /// ファイル名（拡張子なし）。UTC の日時とミリ秒なので、続けて録っても重ならず、名前の順が録った順になる
    public static func baseName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }

    /// recorded_at はミリ秒まで書く（ファイル名と同じ時刻に戻せるように）
    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// wav（元の音質・16bit・モノラル）と json を、録った時刻の名前で1組書く
    @discardableResult
    public static func save(samples: [Float], record: Record,
                            to directory: URL = defaultDirectory) throws -> (wav: URL, json: URL) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = baseName(for: isoFormatter.date(from: record.recordedAt) ?? Date())
        let wav = directory.appendingPathComponent("\(name).wav")
        let json = directory.appendingPathComponent("\(name).json")
        try WAV.encode(samples: samples, sampleRate: record.sampleRate).write(to: wav, options: .atomic)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(record).write(to: json, options: .atomic)
        return (wav, json)
    }

    /// たまった量
    public struct Totals: Equatable {
        public var count: Int
        public var seconds: Double

        public init(count: Int, seconds: Double) {
            self.count = count
            self.seconds = seconds
        }

        /// メニューに出す「12件・3.4分」
        public var menuLabel: String {
            "\(count)件・\(String(format: "%.1f", seconds / 60))分"
        }
    }

    /// 置き場所の json を数える。置き場所が無ければ 0件
    public static func totals(in directory: URL = defaultDirectory) -> Totals {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var totals = Totals(count: 0, seconds: 0)
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(Record.self, from: data) else { continue }
            totals.count += 1
            totals.seconds += record.seconds
        }
        return totals
    }
}
