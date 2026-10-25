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

case "--hud-snapshot":
    // 録音中のポップアップの見た目を、画面に出さずに PNG に書き出す（学習用に残すボタンのオン・オフ・なしの3枚）
    _ = NSApplication.shared
    let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst(2).first ?? ".")
    for (name, training) in [("hud-training-on", true as Bool?), ("hud-training-off", false), ("hud-no-button", nil)] {
        let url = folder.appendingPathComponent("\(name).png")
        try? HUDPanel().writeRecordingSnapshot(training: training, to: url)
        print(url.path)
    }
    // メニューバーのアイコン（18pt）を、待機中（白で描いて見せる）・学習用に残す・録音中の順に並べて書き出す
    let iconURL = folder.appendingPathComponent("menu-icon.png")
    let strip = NSImage(size: NSSize(width: 120, height: 30), flipped: false) { rect in
        NSColor(white: 0.12, alpha: 1).setFill()
        rect.fill()
        SpeakingHeadIcon.draw(in: NSRect(x: 12, y: 6, width: 18, height: 18), color: .white, badge: false)
        SpeakingHeadIcon.image(.training).draw(in: NSRect(x: 50, y: 6, width: 18, height: 18))
        SpeakingHeadIcon.image(.recording).draw(in: NSRect(x: 88, y: 6, width: 18, height: 18))
        return true
    }
    if let tiff = strip.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        try? png.write(to: iconURL)
        print(iconURL.path)
    }
    exit(0)

default:
    break
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
