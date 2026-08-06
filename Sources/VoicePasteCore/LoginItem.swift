import Foundation

/// ログイン時の自動起動（launchd のユーザーエージェント）の登録を読み書きする。
///
/// 入口は2つある。
///   - メニューバーの「ログイン時に起動」（登録ファイルを置く/消すだけ。次回ログインから効く）
///   - `install-autostart.sh`（登録に加えて launchd へ即時読み込みまでする）
/// どちらもこの型を通すので、登録内容が2か所で食い違うことがない。
///
/// 以前は `SMAppService.mainApp` を使っていたが、`build.sh` が毎回 `build/VoicePaste.app` を
/// 作り直すため、アプリのバンドル自体を追跡する方式だと再ビルドのたびに登録が壊れた。
/// launchd はパスを指しているだけなので作り直しても効き続ける。
public enum LoginItem {
    public static let label = "com.sasuu.voicepaste"

    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    public static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VoicePaste.log")
    }

    /// このプロセス自身の実行ファイル。アプリとして動いていればバンドル内のバイナリを指す
    public static var currentExecutablePath: String {
        Bundle.main.executableURL?.resolvingSymlinksInPath().path
            ?? CommandLine.arguments[0]
    }

    // MARK: - 登録内容

    /// launchd に渡す設定。
    /// - `RunAtLoad`: ログイン時に起動する
    /// - `KeepAlive.SuccessfulExit = false`: 異常終了した時だけ起動し直す。
    ///   メニューから終了した時は正常終了（exit 0）なので立ち上がってこない
    /// - `ProcessType = Interactive`: GUIアプリなので通常の優先度で動かす
    public static func plistDictionary(executablePath: String, logPath: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 10,
            "ProcessType": "Interactive",
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
    }

    /// 登録ファイルの中身を作る。パスに `&` や `<` が入っていてもXMLとして壊れない
    public static func plistData(executablePath: String, logPath: String) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: plistDictionary(executablePath: executablePath, logPath: logPath),
            format: .xml,
            options: 0
        )
    }

    /// 登録ファイルが「どの実行ファイルを起動する設定になっているか」を読む
    public static func registeredExecutablePath(plistData data: Data) -> String? {
        guard
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dict = plist as? [String: Any],
            let arguments = dict["ProgramArguments"] as? [String]
        else { return nil }
        return arguments.first
    }

    // MARK: - 状態の読み書き

    /// 登録済みか。
    /// 別の場所にあるVoicePasteを指す古い登録が残っている場合は「未登録」として扱う。
    /// そのまま「登録済み」に見せると、オンなのに起動してこない状態が直せなくなるため
    public static func isEnabled(executablePath: String = currentExecutablePath) -> Bool {
        guard let data = try? Data(contentsOf: plistURL) else { return false }
        return registeredExecutablePath(plistData: data) == executablePath
    }

    /// 登録する。次回ログインから起動するようになる（いま起動し直したい場合は `bootstrapNow()`）
    public static func enable(executablePath: String = currentExecutablePath) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try plistData(executablePath: executablePath, logPath: logURL.path)
        try data.write(to: plistURL, options: .atomic)
    }

    /// 登録を消す。動いているVoicePasteはそのまま動き続ける（次のログインから起動しなくなる）
    public static func disable() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: plistURL.path) else { return }
        try fileManager.removeItem(at: plistURL)
    }

    // MARK: - launchd への即時反映（コマンドラインからの実行用）

    public static var guiDomain: String { "gui/\(getuid())" }

    @discardableResult
    static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// 次のログインを待たずに、いま launchd に読み込ませて起動する
    @discardableResult
    public static func bootstrapNow() -> Bool {
        runLaunchctl(["bootout", "\(guiDomain)/\(label)"])  // 既に読み込まれていれば一度外す
        return runLaunchctl(["bootstrap", guiDomain, plistURL.path]) == 0
    }

    /// launchd から外す。launchd が起動したVoicePasteが動いていれば、それも終了する
    public static func bootoutNow() {
        runLaunchctl(["bootout", "\(guiDomain)/\(label)"])
    }
}
