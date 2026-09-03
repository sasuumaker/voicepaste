import Foundation

/// Whisper が無音・ノイズから作り出すことが分かっている文（幻覚句）の照合。
///
/// `SpeechPresence` で止めきれなかった音（息がマイクにかかった等）を Whisper に送ると、
/// 動画の締めの挨拶がそのまま返ってくる（実測 2026-09-03: 無音・部屋のノイズ・息のいずれも
/// 「ご視聴ありがとうございました。」。transcript-debug.log の幻覚3件も全て同じ句）。
///
/// **全文一致のときだけ** 捨てる。本物の発話の一部にこれらの句が含まれても手を付けない
/// （「ありがとうございました」のような普通の言葉は載せない。
/// 短い相槌「はい」「どうぞ」もノイズから出ることがあるが、本物と区別できないので載せない）。
public enum KnownHallucinations {
    public static let phrases: [String] = [
        "ご視聴ありがとうございました",
        "ご視聴ありがとうございます",
        "ご視聴いただきありがとうございました",
        "ご視聴いただきありがとうございます",
        "最後までご視聴いただきありがとうございました",
        "最後までご視聴ありがとうございました",
        "チャンネル登録お願いします",
        "チャンネル登録をお願いします",
        "チャンネル登録よろしくお願いします",
        "チャンネル登録をよろしくお願いします",
        "thank you for watching",
        "thanks for watching",
    ]

    private static let normalizedPhrases: Set<String> = Set(phrases.map(normalize))

    /// 空白・句読点・記号を落として小文字に揃える。「ご視聴ありがとうございました。」と
    /// 「ご視聴ありがとうございました」を同じものとして扱うため
    public static func normalize(_ text: String) -> String {
        let dropped: Set<Character> = ["。", "、", "．", "，", ".", ",", "!", "?", "！", "？", "…", "「", "」", "\"", "'", "・"]
        return String(text.lowercased().filter { !$0.isWhitespace && !dropped.contains($0) })
    }

    /// 認識結果が幻覚句そのものか（全文一致）
    public static func isKnownPhrase(_ text: String) -> Bool {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return false }
        return normalizedPhrases.contains(normalized)
    }
}
