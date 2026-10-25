import AppKit
import AVFoundation
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
    /// 録音〜認識のあいだだけ登録する Esc の登録ID。待機中は Esc を奪わない
    private var cancelHotKeyID: UInt32?
    /// 1回の「録音〜貼り付け」の通し番号。取り消したら進めて、遅れて返ってきた認識結果を捨てる
    private var runID = 0
    private var transcribeTask: Task<Void, Never>?
    private var lastError: String?
    /// リアルタイム字幕が出せなかった理由。録音の成否とは別なので lastError と混ぜない
    private var liveCaptionNote: String?
    private var liveTranscriber: LiveTranscriber?
    /// いま（直近）の録音に使ったマイクの名前。ポップアップ・メニュー・診断ログに出す
    private var currentMicName: String?
    /// 設定どおりのマイクを使えなかった理由（設定したマイクが未接続など）。使えていれば nil
    private var micNote: String?
    private lazy var settingsController = SettingsWindowController(config: config)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let note = AudioCallTimeout.takeRestartNote() {
            lastError = note
            showHUDError(note)
        }
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
        cancelHotKeyID = nil  // unregisterAll でまとめて外れたので、持っているIDは無効
        if let toggle = HotKeySpec.parse(config.hotkey_toggle) {
            let id = hotkeys.register(toggle) { [weak self] in self?.toggleRecording() }
            if id == nil { lastError = "ホットキー登録失敗: \(config.hotkey_toggle)（他アプリと競合？）" }
        } else {
            lastError = "ホットキーを解釈できません: \(config.hotkey_toggle)"
        }
        if let pasteLast = HotKeySpec.parse(config.hotkey_paste_last) {
            let id = hotkeys.register(pasteLast) { [weak self] in self?.pasteLast() }
            if id == nil { lastError = "ホットキー登録失敗: \(config.hotkey_paste_last)（他アプリと競合？）" }
        } else {
            lastError = "ホットキーを解釈できません: \(config.hotkey_paste_last)"
        }
        if let edit = HotKeySpec.parse(config.hotkey_edit) {
            let id = hotkeys.register(
                edit,
                onRelease: { [weak self] in self?.editKeyReleased() },
                handler: { [weak self] in self?.editKeyPressed() }
            )
            if id == nil { lastError = "ホットキー登録失敗: \(config.hotkey_edit)（他アプリと競合？）" }
        } else {
            lastError = "ホットキーを解釈できません: \(config.hotkey_edit)"
        }
        // 設定保存が録音中と重なった場合、いま奪っていた Esc を付け直す
        if isRecording || isTranscribing { beginCancelHotkey() }
        rebuildMenu()
    }

    // MARK: - 取り消し（Esc）

    /// Esc は**録音〜認識のあいだだけ**奪う。
    /// 修飾キーなしのホットキーを常時登録すると、他アプリの Esc（ダイアログを閉じる・vim 等）を
    /// ずっと横取りしてしまう。取り消しが要る数秒だけ借りて、終わったらすぐ返す
    private func beginCancelHotkey() {
        guard cancelHotKeyID == nil, let esc = HotKeySpec.parse("escape") else { return }
        // 登録できなくても録音は続ける（他アプリが Esc を握っている場合など）。
        // 従来どおりホットキーの再押下で停止できるので、ここで止める理由はない
        cancelHotKeyID = hotkeys.register(esc) { [weak self] in
            // 取り消しの中で Esc 自身を登録解除する。Carbon がそのイベントを処理している最中に
            // 解除するのは避けたいので、1ターン後ろへ逃がす（体感では同時）
            DispatchQueue.main.async { self?.cancelCurrent() }
        }
    }

    private func endCancelHotkey() {
        guard let id = cancelHotKeyID else { return }
        hotkeys.unregister(id)
        cancelHotKeyID = nil
    }

    /// 録音中／認識中に Esc。録った音も認識結果も捨てて、何も貼らずに待機へ戻る
    @objc private func cancelCurrent() {
        guard isRecording || isTranscribing else { return }
        runID += 1  // 途中の認識が遅れて返ってきても、この番号で弾かれる
        transcribeTask?.cancel()
        transcribeTask = nil
        if isRecording {
            _ = withAudioTimeout("録音の停止") { recorder.stop() }  // WAVは受け取らずに捨てる
            stopLiveCaption()
            isRecording = false
        }
        isTranscribing = false
        recordingMode = .dictation
        endCancelHotkey()
        lastError = nil
        NSSound(named: "Tink")?.play()
        if config.hud_enabled { hud.showCancelled() } else { hud.hide() }
        updateIcon()
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

        // 録音に使うマイクは毎回決め直す（AirPodsのつなぎ外しで一覧が変わるため）
        let devices = AudioInputDevices.list()
        let mic = InputDeviceSelection.resolve(setting: config.input_device, devices: devices.map(\.info))
        let deviceID = devices.first { $0.info.uid == mic.device?.uid }?.id
        currentMicName = mic.device?.name
        micNote = mic.note

        if config.hud_enabled {
            hud.showRecording(
                isEdit: isEdit,
                hint: hotkeySymbol(isEdit ? config.hotkey_edit : config.hotkey_toggle),
                mic: currentMicName
            )
            recorder.onLevel = { [weak self] level in self?.hud.updateLevel(level) }
        } else {
            recorder.onLevel = nil
        }
        startLiveCaptionIfEnabled()

        // Groq への接続を録音中に済ませておく（止めたあとの認識が TLS の握手ぶん ≈0.2秒 速くなる）
        if let apiKey = config.resolvedAPIKey { GroqClient.warmUp(apiKey: apiKey) }

        do {
            // 開始音はマイクが実際に生きてから鳴らす（ポンが鳴ったら喋ってOKの合図）
            try withAudioTimeout("録音の開始") {
                try recorder.start(deviceID: deviceID, onCaptureLive: {
                    NSSound(named: "Pop")?.play()
                })
            }
            isRecording = true
            lastError = nil
            beginCancelHotkey()
        } catch {
            TranscriptDebugLog.writeAudioProblem("★開始できず: \(error.localizedDescription)", mic: currentMicName)
            lastError = error.localizedDescription
            NSSound(named: "Basso")?.play()
            stopLiveCaption()
            endCancelHotkey()
            showHUDError(error.localizedDescription)
        }
        updateIcon()
        rebuildMenu()
    }

    /// マイクの開始・停止を、止まったらアプリを起動し直す歯止め付きで行う（`AudioCallTimeout`）
    private func withAudioTimeout<T>(_ step: String, _ body: () throws -> T) rethrows -> T {
        let timeout = AudioCallTimeout(step: step, mic: currentMicName)
        defer { timeout.cancel() }
        return try body()
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
            CaptionDebugLog.writeUnavailable(reason: reason)
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
        let wav = withAudioTimeout("録音の停止") { recorder.stop() }
        stopLiveCaption()
        isRecording = false

        // 短すぎる（誤爆）録音は無視
        guard seconds >= 0.3 else {
            endCancelHotkey()
            hud.hide()
            updateIcon()
            rebuildMenu()
            return
        }

        let micName = currentMicName.map { String(format: "%@（音量ピーク %.2f）", $0, recorder.lastPeak) }
        let speech = recorder.lastSpeech

        // 何も言わずに止めた録音は Groq へ送らない。送ると無音やノイズから
        // 「ご視聴ありがとうございました」等の文が作られ、そのまま貼られてしまう（実測 2026-09-03）
        if let speech, !speech.hasSpeech {
            TranscriptDebugLog.writeSilent(speech: speech.summary, mic: micName)
            finishWithoutPasting()
            return
        }

        guard let apiKey = config.resolvedAPIKey else {
            let message = "APIキー未設定。設定画面から Groq APIキー を入れてください"
            lastError = message
            NSSound(named: "Basso")?.play()
            endCancelHotkey()
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
        let speechSummary = speech?.summary
        runID += 1
        let thisRun = runID
        transcribeTask = Task {
            do {
                let transcribeStarted = Date()
                let transcript = try await client.transcribe(wav: wav)
                let transcribeSeconds = Date().timeIntervalSince(transcribeStarted)
                // 無音判定をすり抜けた音（息がマイクにかかった等）から Whisper が作る決まり文句は、
                // 全文一致のときだけ「何も言っていない」として扱う
                let isHallucination = KnownHallucinations.isKnownPhrase(transcript)
                let raw = isHallucination ? "" : transcript
                let text: String
                // 整形に失敗しても貼り付けは止めないが、失敗したことはメニューに出す
                var cleanupFailure: String?
                switch mode {
                case .dictation:
                    if isHallucination {
                        TranscriptDebugLog.writeHallucination(raw: transcript, mic: micName, speech: speechSummary)
                        text = ""
                    } else if cleanupConfig.cleanup_enabled, !raw.isEmpty {
                        // 整形失敗時は生テキストにフォールバック（貼り付けを止めない）。
                        // ただし理由は必ずログに残す。残していなかったせいで、整形モデルの廃止に9日間気づけなかった（2026-08-29）
                        let cleaner = GroqClient(apiKey: apiKey, model: cleanupConfig.cleanup_model)
                        let cleanupStarted = Date()
                        do {
                            let result = try await cleaner.cleanup(text: raw)
                            text = result.text
                            TranscriptDebugLog.write(
                                raw: raw, candidate: result.candidate, accepted: result.accepted, mic: micName,
                                speech: speechSummary,
                                timing: TranscriptDebugLog.timingLine(
                                    transcribe: transcribeSeconds, cleanup: Date().timeIntervalSince(cleanupStarted),
                                    model: result.model, fallbackNote: result.fallbackNote
                                )
                            )
                        } catch {
                            text = raw
                            cleanupFailure = error.localizedDescription
                            TranscriptDebugLog.write(raw: raw, candidate: nil, accepted: nil,
                                                     note: "★整形に失敗: \(error.localizedDescription)", mic: micName,
                                                     speech: speechSummary,
                                                     timing: TranscriptDebugLog.timingLine(
                                                         transcribe: transcribeSeconds,
                                                         cleanup: Date().timeIntervalSince(cleanupStarted),
                                                         model: nil, fallbackNote: nil, cleanupFailed: true
                                                     ))
                        }
                    } else {
                        text = raw
                        TranscriptDebugLog.write(raw: raw, candidate: nil, accepted: nil,
                                                 note: cleanupConfig.cleanup_enabled ? "無音（整形にかけない）" : "整形オフ", mic: micName,
                                                 speech: speechSummary,
                                                 timing: TranscriptDebugLog.timingLine(
                                                     transcribe: transcribeSeconds, cleanup: nil, model: nil, fallbackNote: nil
                                                 ))
                    }
                case .edit(let selection):
                    // 指示が無音なら何もしない。編集APIが失敗したら throw → エラー表示
                    // （生の指示テキストを貼ると選択部分が壊れるため、フォールバック貼り付けはしない）
                    guard !raw.isEmpty else {
                        EditDebugLog.write(selection: selection,
                                           instruction: isHallucination ? "(幻覚句: \(transcript))" : "(無音)", result: nil)
                        text = ""
                        break
                    }
                    let editor = GroqClient(apiKey: apiKey, model: cleanupConfig.cleanup_model)
                    do {
                        let edited = try await editor.edit(selection: selection, instruction: raw)
                        text = edited.text
                        EditDebugLog.write(selection: selection, instruction: raw, result: text,
                                           model: edited.model, fallbackNote: edited.fallbackNote)
                    } catch {
                        EditDebugLog.write(selection: selection, instruction: raw, result: nil,
                                           error: error.localizedDescription)
                        throw error
                    }
                }
                let cleanupFailureNote = cleanupFailure
                await MainActor.run {
                    // Esc で取り消したあとに遅れて返ってきた結果は貼らない
                    guard self.runID == thisRun else { return }
                    self.transcribeTask = nil
                    if let cleanupFailureNote {
                        self.lastError = "整形に失敗（生テキストを貼りました）: \(cleanupFailureNote)"
                    }
                    self.handleTranscription(text)
                }
            } catch {
                await MainActor.run {
                    guard self.runID == thisRun else { return }
                    self.transcribeTask = nil
                    self.isTranscribing = false
                    self.endCancelHotkey()
                    self.lastError = error.localizedDescription
                    NSSound(named: "Basso")?.play()
                    self.showHUDError(error.localizedDescription)
                    self.updateIcon()
                    self.rebuildMenu()
                }
            }
        }
    }

    /// 何も言っていなかった（声なし・認識結果が空・幻覚句）ので何も貼らずに待機へ戻る。
    /// 取り消しと同じ扱いで、エラーではない。警告音もメニューの「⚠️」も出さず、短く知らせるだけ
    private func finishWithoutPasting() {
        isTranscribing = false
        endCancelHotkey()
        NSSound(named: "Tink")?.play()
        if config.hud_enabled { hud.showInfo("無音でした（何も貼りません）") } else { hud.hide() }
        updateIcon()
        rebuildMenu()
    }

    private func handleTranscription(_ text: String) {
        guard !text.isEmpty else {
            finishWithoutPasting()
            return
        }
        isTranscribing = false
        endCancelHotkey()
        history.insert(text, at: 0)
        if history.count > 20 { history.removeLast() }
        let source: String
        if case .edit = recordingMode { source = "編集モード" } else { source = "音声入力" }
        // 「貼り付けました」は実際に送った瞬間に出す（表示と実物がズレないように）
        let pasted = Paster.paste(
            text, source: source, viaClipboard: config.paste_via_clipboard
        ) { [weak self] in
            self?.showHUDResult(text)
        }
        if !pasted {
            let message = "クリップボードにコピーしました。自動貼り付けにはアクセシビリティ権限が必要です"
            lastError = message
            showHUDResult(text, prefix: "コピーしました（\(hotkeySymbol(config.hotkey_paste_last)) で貼り付け）")
        }
        NSSound(named: "Glass")?.play()
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
        let pasted = Paster.paste(
            last, source: "再貼り付け", viaClipboard: config.paste_via_clipboard
        ) { [weak self] in
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
                return "🔴 編集指示を録音中… (もう一度押して停止 / ⎋ で取り消し)"
            }
            return "🔴 録音中… (\(hotkeySymbol(config.hotkey_toggle)) で停止 / ⎋ で取り消し)"
        }
        if isTranscribing { return "⏳ 認識中… (⎋ で取り消し)" }
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

        let micItem = NSMenuItem(title: "🎤 マイク: \(currentMicName ?? "（次の録音で決まります）")", action: nil, keyEquivalent: "")
        micItem.isEnabled = false
        menu.addItem(micItem)
        if let micNote {
            let item = NSMenuItem(title: "⚠️ \(String(micNote.prefix(60)))", action: nil, keyEquivalent: "")
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
        loginItem.state = LoginItem.isEnabled() ? .on : .off
        loginItem.toolTip = "次回ログインから有効になります"
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

    /// 自動起動のオン/オフ。登録ファイルを置く・消すだけなので、いま動いているVoicePasteには影響しない
    @objc private func toggleLoginItem() {
        do {
            if LoginItem.isEnabled() {
                try LoginItem.disable()
            } else {
                try LoginItem.enable()
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
