import Foundation

/// 整形結果を採用してよいかを機械的に判定する。
///
/// 整形は「句読点を足す・つなぎ言葉を消す」だけの工程で、中身を書き換えてはいけない。
/// ところが渡すのはユーザーの自由な発話なので、それが指示の形をしていると、
/// 整形モデルが整形するかわりに**指示として実行して答えてしまう**ことがある
/// （実測・2026-08-10。普段の発話8件中1件。「この構成のメリットとデメリットを箇条書きで出して」→
/// 整形結果がAIの回答文になり、`collapseAddedNewlines` が畳んで1行の長文として貼られた）。
///
/// プロンプトで禁じても確率が下がるだけでゼロにはならない。自由発話をLLMに渡して
/// 「指示として読むな」と頼む形そのものが原因なので、歯止めは機械側に置く。
///
/// 判定の考え方: **消すのは許す、足すのは許さない。**
/// つなぎ言葉の除去で短くなるのは正常なので、長さの増減では測らない。
/// 「整形後の文字が、どれだけ元テキストに由来しているか」だけを見る。
/// モデルが勝手に書いた文章は元テキストに無い文字でできているので、ここで落ちる。
public enum CleanupGuard {
    /// 整形後の文字のうち、元テキスト由来であるべき割合の下限
    public static let minContainment = 0.8
    /// 元テキストに対して整形後が伸びてよい上限（句読点ぶんの余裕を含む）
    public static let maxGrowth = 1.5
    /// この長さを超えたら、重い突き合わせをやめて長さの判定だけにする
    private static let comparisonLimit = 2000

    /// - Returns: 整形結果を採用してよければ true。false なら生テキストを使う
    public static func accept(raw: String, cleaned: String) -> Bool {
        let rawCore = core(of: raw)
        let cleanedCore = core(of: cleaned)

        // 中身のある発話が空になったら、整形ではなく消失
        if rawCore.isEmpty { return cleanedCore.isEmpty }
        if cleanedCore.isEmpty { return false }

        // 句読点を足すだけなら中身の文字数はほぼ増えない。増えていたら書き足している
        if Double(cleanedCore.count) > Double(rawCore.count) * maxGrowth + 8 { return false }

        guard rawCore.count <= comparisonLimit, cleanedCore.count <= comparisonLimit else { return true }

        let shared = longestCommonSubsequenceLength(rawCore, cleanedCore)
        return Double(shared) / Double(cleanedCore.count) >= minContainment
    }

    /// 比較に使う「中身の文字」だけを取り出す。
    /// 句読点と空白は整形が足したり削ったりする前提のものなので、判定から外す
    public static func core(of text: String) -> [Character] {
        text.unicodeScalars
            .filter {
                !CharacterSet.whitespacesAndNewlines.contains($0)
                    && !CharacterSet.punctuationCharacters.contains($0)
                    && !CharacterSet.symbols.contains($0)
            }
            .map { Character($0) }
    }

    /// 2つの並びが共有している最長の並び。順序を保ったまま何文字が引き継がれたかを測る
    public static func longestCommonSubsequenceLength(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty || b.isEmpty { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = previous
        for i in 1...a.count {
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1] + 1
                    : max(previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
