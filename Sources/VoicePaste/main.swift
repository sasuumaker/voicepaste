import AppKit
import VoicePasteCore

// 自動起動の登録・解除をコマンドラインから行う（install-autostart.sh から呼ばれる）。
// GUIを立ち上げる前に処理して終了する
switch CommandLine.arguments.dropFirst().first {
case "--install-autostart":
    do {
        try LoginItem.enable()
    } catch {
        FileHandle.standardError.write(
            Data("❌ 自動起動を登録できませんでした: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    let started = LoginItem.bootstrapNow()
    print("✅ 自動起動を登録しました\(started ? "（いま起動しました）" : "（次回ログインから有効）")")
    print("   設定ファイル: \(LoginItem.plistURL.path)")
    print("   ログ:         \(LoginItem.logURL.path)")
    exit(0)

case "--uninstall-autostart":
    LoginItem.bootoutNow()
    do {
        try LoginItem.disable()
    } catch {
        FileHandle.standardError.write(
            Data("❌ 自動起動を解除できませんでした: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    print("✅ 自動起動の登録を解除しました（アプリ本体は消していません）")
    exit(0)

case "--selftest-record":
    // 録音の開始・停止をくり返す実機確認（RecorderSelfTest.swift に起動のしかた）
    let options = Array(CommandLine.arguments.dropFirst(2))
    let cycles = options.first.flatMap { Int($0) } ?? 20
    let seconds = options.dropFirst().first.flatMap { TimeInterval($0) } ?? 0.5
    exit(RecorderSelfTest.run(cycles: cycles, seconds: seconds, saveLastTo: options.dropFirst(2).first))

default:
    break
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
