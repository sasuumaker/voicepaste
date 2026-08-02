import AppKit
import AVFoundation
import ServiceManagement
import VoicePasteCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 録音の用途。dictation=カーソル位置に入力、edit=選択テキストを音声指示で書き換え
    private enum RecordingMode {
        case dictation
        case edit(selection: String)
    }

    private var statusItem: NSStatusItem!
    private let recorder = AudioRecorder()
    private let hotkeys = HotKeyManager()
    private let hud = HUDPanel()
    private var config = Config.load()
    private var history: [String] = []
    private var isRecording = false
    private var isTranscribing = false
    private var recordingMode: RecordingMode = .dictation
    private var editPressStartedAt: Date?
    private var lastError: String?
    /// リアルタイム字幕が出せなかった理由。録音の成否とは別なので lastError と混ぜない
    private var liveCaptionNote: String?
    private var liveTranscriber: LiveTranscriber?
    private lazy var settingsController = SettingsWindowController(config: config)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()
        rebuildMenu()
        requestPermissions()
        registerHotkeys()
    }

    // MARK: - Permissions

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                DispatchQueue.main.async { [weak self] in
                    self?.lastError = "マイク権限がありません（システム設定 > プライバシー > マイク）"
                    self?.rebuildMenu()
                }
            }
        }
        // 自動貼り付け（Cmd+V送信）に必要。未許可ならプロンプトを出す
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        requestSpeechPermissionIfNeeded()
    }

    /// リアルタイム字幕を使う設定のときだけ、音声認識の許可を求める
    private func requestSpeechPermissionIfNeeded() {
        guard config.live_caption_enabled, LiveTranscriber.isUndetermined else { return }
        LiveTranscriber.requestAuthorization { _ in }
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        hotkeys.unregisterAll()
        if let toggle = HotKeySpec.parse(config.hotkey_toggle) {
            let ok = hotkeys.register(toggle) { [weak self] in self?.toggleRecording() }
            if !ok { lastError = "ホットキー登録失敗: \(config.hotkey_toggle)（他アプリと競合？）" }
        } else {
            lastError = "ホットキーを解釈できません: \(config.hotkey_toggle)"
        }
        if let pasteLast = HotKeySpec.parse(config.hotkey_paste_last) {
            let ok = hotkeys.register(pasteLast) { [weak self] in self?.pasteLast() }
            if !ok { lastError = "ホットキー登録失敗: \(config.hotkey_paste_last)（他アプリと競合？）" }
        } else {
            lastError = "ホットキーを解釈できません: \(config.hotkey_paste_last)"
        }
        if let edit = HotKeySpec.parse(config.hotkey_edit) {
            let ok = hotkeys.register(
                edit,
                onRelease: { [weak self] in self?.editKeyReleased() },
                handler: { [weak self] in self?.editKeyPressed() }
            )
            if !ok { lastError = "ホットキー登録失敗: \(config.hotkey_edit)（他アプリと競合？）" }
        } else {
            lastError = "ホットキーを解釈できません: \(config.hotkey_edit)"
        }
        rebuildMenu()
    }

    // MARK: - Recording flow

    @objc private func toggleRecording() {
        if isRecording {
            finishRecording()
        } else {
            recordingMode = .dictation
            startRecording()
        }
    }

    /// 編集モード: テキスト選択中にホットキー → 選択を取得して録音開始。
    /// 操作は2通りどちらでも動く:
    /// - 押しっぱなし（Wispr式）: 押している間だけ録音、離すと確定
    /// - トグル（短押し）: 押して録音開始 → もう一度押して確定
    @objc private func editKeyPressed() {
        if isRecording {
            // どのモードで録音中でも、編集キーでも停止できる（誤操作で詰まらせない）
            finishRecording()
            return
        }
        guard let selection = SelectionReader.read(), !selection.isEmpty else {
            let message = "テキストが選択されていません（選択してから \(hotkeySymbol(config.hotkey_edit)) を押してください）"
            lastError = message
            NSSound(named: "Basso")?.play()
            showHUDError(message)
            rebuildMenu()
            return
        }
        recordingMode = .edit(selection: selection)
        editPressStartedAt = Date()
        startRecording()
    }

    /// 編集キーを離した: 0.8秒以上押しっぱなしだったら「押している間だけ録音」とみなして確定。
    /// 短押し（トグルの1回目）なら何もしない＝次の押下で確定する。
    @objc private func editKeyReleased() {
        guard isRecording, case .edit = recordingMode,
              let started = editPressStartedAt else { return }
        if Date().timeIntervalSince(started) >= 0.8 {
            finishRecording()
        }
    }

    private func startRecording() {
        guard !isTranscribing else { return }
        let isEdit: Bool
        if case .edit = recordingMode { isEdit = true } else { isEdit = false }

        if config.hud_enabled {
            hud.showRecording(
                isEdit: isEdit,
                hint: hotkeySymbol(isEdit ? config.hotkey_edit : config.hotkey_toggle)
            )
            recorder.onLevel = { [weak self] level in self?.hud.updateLevel(level) }
        } else {
            recorder.onLevel = nil
        }
        startLiveCaptionIfEnabled()

        do {
            // 開始音はマイクが実際に生きてから鳴らす（ポンが鳴ったら喋ってOKの合図）
            try recorder.start(onCaptureLive: {
                NSSound(named: "Pop")?.play()
            })
            isRecording = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            NSSound(named: "Basso")?.play()
            stopLiveCaption()
            showHUDError(error.localizedDescription)
        }
        updateIcon()
        rebuildMenu()
    }

    /// 録音中の「いま喋っている内容」表示。あくまで見た目用で、確定テキストはGroqが作る
    private func startLiveCaptionIfEnabled() {
        liveCaptionNote = nil
        guard config.hud_enabled, config.live_caption_enabled else { return }
        let transcriber = LiveTranscriber(localeIdentifier: config.live_caption_locale)
        transcriber.onText = { [weak self] text in self?.hud.updateCaption(text) }
        if let reason = transcriber.start() {
            // 字幕が出せなくても録音自体は続ける（音量メーターで入力は分かる）。
            // ただし黙って出ないと故障に見えるので、理由をポップアップとメニューの両方に出す
            liveCaptionNote = reason
            hud.showCaptionUnavailable(reason)
            return
        }
        liveTranscriber = transcriber
        recorder.onBuffer = { [weak transcriber] buffer in transcriber?.append(buffer) }
    }

    private func stopLiveCaption() {
        liveTranscriber?.stop()
        liveTranscriber = nil
    }

    private func finishRecording() {
        let seconds = recorder.recordedSeconds
        let wav = recorder.stop()
        stopLiveCaption()
        isRecording = false

        // 短すぎる（誤爆）録音は無視
        guard seconds >= 0.3 else {
            hud.hide()
            updateIcon()
            rebuildMenu()
            return
        }

        guard let apiKey = config.resolvedAPIKey else {
            let message = "APIキー未設定。設定画面から Groq APIキー を入れてください"
            lastError = message
            NSSound(named: "Basso")?.play()
            showHUDError(message)
            updateIcon()
            rebuildMenu()
            return
        }

        isTranscribing = true
        NSSound(named: "Bottle")?.play()
        if config.hud_enabled { hud.showTranscribing() }
        updateIcon()
        rebuildMenu()

        let client = GroqClient(apiKey: apiKey, model: config.model)
        let cleanupConfig = config
        let mode = recordingMode
        Task {
            do {
                let raw = try await client.transcribe(wav: wav)
                let text: String
                switch mode {
                case .dictation:
                    if cleanupConfig.cleanup_enabled, !raw.isEmpty {
                        // 整形失敗時は生テキストにフォールバック（貼り付けを止めない）
                        let cleaner = GroqClient(apiKey: apiKey, model: cleanupConfig.cleanup_model)
                        text = (try? await cleaner.cleanup(text: raw)) ?? raw
                    } else {
                        text = raw
                    }
                case .edit(let selection):
                    // 指示が無音なら何もしない。編集APIが失敗したら throw → エラー表示
                    // （生の指示テキストを貼ると選択部分が壊れるため、フォールバック貼り付けはしない）
                    guard !raw.isEmpty else {
                        EditDebugLog.write(selection: selection, instruction: "(無音)", result: nil)
                        text = ""
                        break
                    }
                    let editor = GroqClient(apiKey: apiKey, model: cleanupConfig.cleanup_model)
                    do {
                        text = try await editor.edit(selection: selection, instruction: raw)
                        EditDebugLog.write(selection: selection, instruction: raw, result: text)
                    } catch {
                        EditDebugLog.write(selection: selection, instruction: raw, result: nil,
                                           error: error.localizedDescription)
                        throw error
                    }
                }
                await MainActor.run { self.handleTranscription(text) }
            } catch {
                await MainActor.run {
                    self.isTranscribing = false
                    self.lastError = error.localizedDescription
                    NSSound(named: "Basso")?.play()
                    self.showHUDError(error.localizedDescription)
                    self.updateIcon()
                    self.rebuildMenu()
                }
            }
        }
    }

    private func handleTranscription(_ text: String) {
        isTranscribing = false
        if text.isEmpty {
            lastError = "無音でした（認識結果が空）"
            showHUDError("無音でした")
        } else {
            history.insert(text, at: 0)
            if history.count > 20 { history.removeLast() }
            let source: String
            if case .edit = recordingMode { source = "編集モード" } else { source = "音声入力" }
            // 「貼り付けました」は実際に送った瞬間に出す（表示と実物がズレないように）
            let pasted = Paster.paste(text, source: source) { [weak self] in
                self?.showHUDResult(text)
            }
            if !pasted {
                let message = "クリップボードにコピーしました。自動貼り付けにはアクセシビリティ権限が必要です"
                lastError = message
                showHUDResult(text, prefix: "コピーしました（\(hotkeySymbol(config.hotkey_paste_last)) で貼り付け）")
            }
            NSSound(named: "Glass")?.play()
        }
        updateIcon()
        rebuildMenu()
    }

    /// 直前の認識結果をもう一度カーソル位置へ。
    /// 入力欄にフォーカスしていない状態で喋ってしまい、どこにも入らなかったときの復旧用
    private func pasteLast() {
        guard let last = history.first else {
            PasteDebugLog.write("再貼り付け", lines: ["結果: 履歴が空なので何もしない"])
            NSSound(named: "Basso")?.play()
            showHUDError("まだ貼り付けられる内容がありません")
            return
        }
        let pasted = Paster.paste(last, source: "再貼り付け") { [weak self] in
            self?.showHUDResult(last, prefix: "もう一度貼り付けました")
        }
        if !pasted {
            showHUDResult(last, prefix: "クリップボードに入れました（手動で ⌘V）")
        }
    }

    // MARK: - HUD

    private func showHUDResult(_ text: String, prefix: String? = nil) {
        guard config.hud_enabled else { return }
        hud.showResult(text, prefix: prefix)
    }

    private func showHUDError(_ text: String) {
        guard config.hud_enabled else { return }
        hud.showError(text)
    }

    private func hotkeySymbol(_ configString: String) -> String {
        HotKeySpec.symbolString(for: configString)
    }

    // MARK: - UI

    private func updateIcon() {
        let symbolName = isRecording ? "mic.fill" : (isTranscribing ? "ellipsis.circle" : "mic")
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "VoicePaste")
        statusItem.button?.image = image
        statusItem.button?.contentTintColor = isRecording ? .systemRed : nil
    }

    private var statusText: String {
        if isRecording {
            if case .edit = recordingMode {
                return "🔴 編集指示を録音中… (もう一度押して停止)"
            }
            return "🔴 録音中… (\(hotkeySymbol(config.hotkey_toggle)) で停止)"
        }
        if isTranscribing { return "⏳ 認識中…" }
        return "待機中 (\(hotkeySymbol(config.hotkey_toggle)) で音声入力 / 選択して \(hotkeySymbol(config.hotkey_edit)) で編集)"
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if let error = lastError {
            let item = NSMenuItem(title: "⚠️ \(String(error.prefix(60)))", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        if let note = liveCaptionNote {
            let item = NSMenuItem(title: "字幕オフ: \(String(note.prefix(60)))", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        if history.isEmpty {
            let item = NSMenuItem(title: "履歴なし", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            let header = NSMenuItem(
                title: "履歴（クリックでコピー / \(hotkeySymbol(config.hotkey_paste_last)) で直前を再貼り付け）",
                action: nil,
                keyEquivalent: ""
            )
            header.isEnabled = false
            menu.addItem(header)
            for (index, text) in history.prefix(10).enumerated() {
                let title = text.count > 40 ? String(text.prefix(40)) + "…" : text
                let item = NSMenuItem(title: title, action: #selector(historyClicked(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "設定…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let loginItem = NSMenuItem(title: "ログイン時に起動", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)

        let openConfig = NSMenuItem(title: "設定ファイルを開く", action: #selector(openConfigFile), keyEquivalent: "")
        openConfig.target = self
        menu.addItem(openConfig)

        let reload = NSMenuItem(title: "設定ファイルを読み直す", action: #selector(reloadConfig), keyEquivalent: "")
        reload.target = self
        menu.addItem(reload)

        menu.addItem(NSMenuItem(title: "VoicePasteを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func historyClicked(_ sender: NSMenuItem) {
        guard sender.tag < history.count else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(history[sender.tag], forType: .string)
    }

    @objc private func openSettings() {
        settingsController.onSave = { [weak self] updated in self?.applySettings(updated) }
        settingsController.show(config: config)
    }

    /// 設定画面の保存。ホットキーは付け替えるだけなのでアプリの再起動は要らない
    private func applySettings(_ updated: Config) {
        do {
            try Config.save(updated)
            lastError = nil
        } catch {
            lastError = "設定を保存できませんでした: \(error.localizedDescription)"
        }
        config = updated
        registerHotkeys()
        requestSpeechPermissionIfNeeded()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            lastError = nil
        } catch {
            lastError = "自動起動の設定に失敗: \(error.localizedDescription)"
        }
        rebuildMenu()
    }

    @objc private func openConfigFile() {
        NSWorkspace.shared.open(Config.configURL)
    }

    /// 設定ファイルを直接書き換えた場合の反映。ホットキーもその場で付け替える
    @objc private func reloadConfig() {
        config = Config.load()
        registerHotkeys()
    }
}
