import AppKit
import Foundation

/// 画面下に出る録音インジケータ。
///
/// 設計上の絶対条件: **キーボードフォーカスを奪わないこと**。
/// 貼り付け先は「いま入力中のアプリ」なので、この窓が一瞬でもキーウィンドウになると
/// 貼り付け先を見失う。そのため nonactivatingPanel + ignoresMouseEvents + orderFrontRegardless で出す。
/// 例外は録音中の「学習用に残す」ボタンだけ。録音中に限ってマウスを受け付けるが、ポップアップは nonactivatingPanel で
/// 枠なし（キーウィンドウになれない）なので、押してもこのアプリは前に出ず、入力中のアプリのキー入力先は変わらない
///
/// 喋った内容は消さずに溜める。文章が増えたら**下端を固定したまま上へ伸びる**。
/// 伸びる上限に達したら、そこから先は古い方を落として最新側を残す。
final class HUDPanel {
    enum State {
        case recording(hint: String, mic: String?)
        case editRecording(hint: String, mic: String?)
        case transcribing
        case result(String)
        case info(String)
        case cancelled
        case error(String)
    }

    private var panel: NSPanel?
    private let meter = LevelMeterView(frame: .zero)
    private let stateLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(labelWithString: "")
    private let trainingButton = FirstClickButton()
    /// 録音中のボタンの状態。nil ならボタンを出さない（編集モード・録音中でないとき）
    private var trainingOn: Bool?
    /// 録音中に「学習用に残す」ボタンが押された。オン・オフの切り替えは AppDelegate が行い、updateTraining で戻す
    var onToggleTraining: (() -> Void)?
    private var hideWorkItem: DispatchWorkItem?
    private var elapsedTimer: Timer?
    private var recordingStartedAt: Date?

    private static let width: CGFloat = 620
    private static let padding: CGFloat = 16
    private static let topRowHeight: CGFloat = 18
    private static let meterWidth: CGFloat = 90
    private static let trainingButtonWidth: CGFloat = 150
    private static let gap: CGFloat = 10
    /// 画面を覆いすぎないための上限。ここを超えたら古い方を落として最新側を残す
    private static let maxTextHeight: CGFloat = 260
    private static let bottomMargin: CGFloat = 120
    private static let textFont = NSFont.systemFont(ofSize: 14, weight: .regular)

    private var textWidth: CGFloat { Self.width - Self.padding * 2 }

    // MARK: - 公開API

    /// - Parameters:
    ///   - mic: 録音に使っているマイクの名前。AirPodsをつないでいても内蔵で録っていることが一目で分かるように出す
    ///   - training: 「学習用に残す」の今の状態。nil ならボタンを出さない（編集モード）
    func showRecording(isEdit: Bool, hint: String, mic: String? = nil, training: Bool? = nil) {
        recordingStartedAt = Date()
        meter.reset()
        trainingOn = training
        setState(isEdit ? .editRecording(hint: hint, mic: mic) : .recording(hint: hint, mic: mic))
        setText(isEdit ? "編集の指示をどうぞ…" : "どうぞ…", dimmed: true)
        show()
        startElapsedTimer()
    }

    /// リアルタイム字幕の途中経過。喋るほど溜まっていく
    func updateCaption(_ text: String) {
        guard !text.isEmpty else { return }
        setText(text, dimmed: false)
    }

    /// 録音中にボタンやメニューで切り替えたとき、ボタンの表示を合わせる
    func updateTraining(_ on: Bool) {
        guard trainingOn != nil else { return }
        trainingOn = on
        refreshTrainingButton()
    }

    func updateLevel(_ level: Float) {
        meter.push(level)
    }

    /// 字幕が出せないときは黙って空欄にせず、理由をその場に出す。
    /// 録音そのものは続いているので、音量メーターで入力は確認できる
    func showCaptionUnavailable(_ reason: String) {
        setText("字幕なしで録音中（\(reason)）", dimmed: true)
    }

    func showTranscribing() {
        stopElapsedTimer()
        meter.fadeOut()
        setState(.transcribing)
        show()
    }

    /// 確定テキスト。しばらく出してから自動で消える
    func showResult(_ text: String, prefix: String? = nil) {
        stopElapsedTimer()
        meter.fadeOut()
        setState(.result(text))
        setText(text, dimmed: false)
        if let prefix { stateLabel.stringValue = prefix }
        show()
        scheduleHide(after: 2.0)
    }

    func showInfo(_ text: String) {
        stopElapsedTimer()
        meter.fadeOut()
        setState(.info(text))
        setText(text, dimmed: false)
        show()
        scheduleHide(after: 2.0)
    }

    /// Esc で取り消したとき。何も貼らずに終わったことをその場で伝える
    func showCancelled() {
        stopElapsedTimer()
        meter.fadeOut()
        setState(.cancelled)
        setText("", dimmed: true)
        show()
        scheduleHide(after: 1.2)
    }

    func showError(_ text: String) {
        stopElapsedTimer()
        meter.fadeOut()
        setState(.error(text))
        setText(text, dimmed: false)
        show()
        scheduleHide(after: 3.5)
    }

    /// 見た目の確かめ用（`VoicePaste --hud-snapshot <フォルダ>`）: 録音中のポップアップを、画面に出さずに PNG にする
    func writeRecordingSnapshot(training: Bool?, to url: URL) throws {
        trainingOn = training
        let panel = panel ?? makePanel()
        setState(.recording(hint: "⌘/", mic: "MacBook Airのマイク"))
        setText("今日は、声のモデルの学習に使う音声入力の試しです。", dimmed: false)
        refreshTrainingButton()
        guard let view = panel.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    func hide() {
        stopElapsedTimer()
        hideWorkItem?.cancel()
        hideWorkItem = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        }
    }

    // MARK: - 中身の更新

    private func setState(_ state: State) {
        // ボタンは録音中（音声入力）だけ。ほかの状態ではマウスを受け付けず、下の画面のクリックを邪魔しない
        if case .recording = state {} else { trainingOn = nil }
        refreshTrainingButton()
        switch state {
        case .recording(let hint, let mic):
            stateLabel.stringValue = "● 録音中   0:00   \(hint) で停止 ／ ⎋ で取り消し" + Self.micSuffix(mic)
            stateLabel.textColor = .systemRed
        case .editRecording(let hint, let mic):
            stateLabel.stringValue = "● 編集指示を録音中   0:00   \(hint) で確定 ／ ⎋ で取り消し" + Self.micSuffix(mic)
            stateLabel.textColor = .systemOrange
        case .transcribing:
            stateLabel.stringValue = "認識中…   ⎋ で取り消し"
            stateLabel.textColor = .secondaryLabelColor
        case .result:
            stateLabel.stringValue = "貼り付けました"
            stateLabel.textColor = .systemGreen
        case .info:
            stateLabel.stringValue = ""
            stateLabel.textColor = .secondaryLabelColor
        case .cancelled:
            stateLabel.stringValue = "取り消しました"
            stateLabel.textColor = .secondaryLabelColor
        case .error:
            stateLabel.stringValue = "⚠️ エラー"
            stateLabel.textColor = .systemOrange
        }
    }

    private func refreshTrainingButton() {
        guard let on = trainingOn else {
            trainingButton.isHidden = true
            panel?.ignoresMouseEvents = true
            return
        }
        trainingButton.isHidden = false
        panel?.ignoresMouseEvents = false
        let title = on ? "● 学習用に残す: オン" : "○ 学習用に残す: オフ"
        trainingButton.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: on ? NSColor.systemGreen : NSColor.secondaryLabelColor,
        ])
        trainingButton.toolTip = on ? "押すとオフ（この回から残さない）" : "押すとオン（この回から残す）"
        relayout()
    }

    private static func micSuffix(_ mic: String?) -> String {
        guard let mic, !mic.isEmpty else { return "" }
        return "   🎤 \(mic)"
    }

    private func setText(_ text: String, dimmed: Bool) {
        textLabel.stringValue = Self.fitted(text, width: textWidth)
        textLabel.textColor = dimmed ? .secondaryLabelColor : .labelColor
        relayout()
    }

    /// 上限を超えたぶんは先頭を落として、いま喋っている末尾を必ず見えるようにする
    private static func fitted(_ text: String, width: CGFloat) -> String {
        guard height(of: text, width: width) > maxTextHeight else { return text }
        let characters = Array(text)
        var low = 0
        var high = characters.count
        while low < high {
            let mid = (low + high) / 2
            let candidate = "…" + String(characters[mid...])
            if height(of: candidate, width: width) > maxTextHeight {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return "…" + String(characters[min(low, characters.count)...])
    }

    private static func height(of text: String, width: CGFloat) -> CGFloat {
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: textFont]
        )
        return ceil(rect.height)
    }

    // MARK: - 表示

    private func show() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        let panel = panel ?? makePanel()
        relayout()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
        }
    }

    /// 文章の量に合わせて高さを決め、**下端を固定したまま上へ伸ばす**。
    /// 下端が動くと目線が追えないので、伸びる方向は上に固定する
    private func relayout() {
        guard let panel else { return }
        let textHeight = max(Self.height(of: "あ", width: textWidth),
                             Self.height(of: textLabel.stringValue, width: textWidth))
        let height = Self.padding * 2 + Self.topRowHeight + Self.gap + textHeight

        let frame = currentScreenFrame()
        panel.setFrame(
            NSRect(x: frame.midX - Self.width / 2,
                   y: frame.minY + Self.bottomMargin,
                   width: Self.width,
                   height: height),
            display: true
        )

        let topRowY = height - Self.padding - Self.topRowHeight
        meter.frame = NSRect(x: Self.padding, y: topRowY + 1, width: Self.meterWidth, height: 16)
        let buttonSpace = trainingButton.isHidden ? 0 : Self.trainingButtonWidth + Self.gap
        stateLabel.frame = NSRect(
            x: Self.padding + Self.meterWidth + Self.gap,
            y: topRowY,
            width: Self.width - Self.padding * 2 - Self.meterWidth - Self.gap - buttonSpace,
            height: Self.topRowHeight
        )
        trainingButton.frame = NSRect(x: Self.width - Self.padding - Self.trainingButtonWidth, y: topRowY - 2,
                                      width: Self.trainingButtonWidth, height: Self.topRowHeight + 4)
        textLabel.frame = NSRect(x: Self.padding, y: Self.padding, width: textWidth, height: textHeight)
    }

    /// マルチディスプレイでは「いま作業している画面」に出す。
    /// NSScreen.main はこのアプリ側のキーウィンドウ基準なので、常駐アプリだと
    /// 打ち込んでいる画面と食い違う。マウスのある画面のほうが実際の作業位置に一致する
    private func currentScreenFrame() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: Self.width, height: 400)
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func startElapsedTimer() {
        stopElapsedTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let started = self.recordingStartedAt else { return }
            let seconds = Int(Date().timeIntervalSince(started))
            let clock = String(format: "%d:%02d", seconds / 60, seconds % 60)
            let base = self.stateLabel.stringValue
            // "● 録音中   0:00   ⌘/ で停止" の時計部分だけ差し替える
            guard let range = base.range(of: #"\d+:\d{2}"#, options: .regularExpression) else { return }
            self.stateLabel.stringValue = base.replacingCharacters(in: range, with: clock)
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = trainingOn == nil
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 18
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]

        stateLabel.font = .systemFont(ofSize: 11, weight: .medium)
        stateLabel.lineBreakMode = .byTruncatingTail

        textLabel.font = Self.textFont
        textLabel.maximumNumberOfLines = 0
        textLabel.usesSingleLineMode = false
        textLabel.cell?.wraps = true
        textLabel.lineBreakMode = .byWordWrapping

        trainingButton.bezelStyle = .inline
        trainingButton.controlSize = .small
        trainingButton.isHidden = true
        trainingButton.onClick = { [weak self] in self?.onToggleTraining?() }

        background.addSubview(meter)
        background.addSubview(stateLabel)
        background.addSubview(textLabel)
        background.addSubview(trainingButton)
        panel.contentView = background
        self.panel = panel
        return panel
    }
}

/// 前に出ていないポップアップの上でも、1回目のクリックで押せるボタン。
/// 普通のボタンは、前に出ていないウィンドウでは1回目のクリックを「ウィンドウを前に出す」ために使い、押されない
final class FirstClickButton: NSButton {
    var onClick: (() -> Void)?

    convenience init() {
        self.init(frame: .zero)
        title = ""
        target = self
        action = #selector(clicked)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func clicked() { onClick?() }
}

/// 音量の履歴を左から右へ流す簡易メーター。「マイクが拾えている」ことを一目で示すためのもの
private final class LevelMeterView: NSView {
    private var levels: [CGFloat] = Array(repeating: 0, count: 30)
    private var fading = false

    func push(_ level: Float) {
        fading = false
        levels.removeFirst()
        levels.append(CGFloat(max(0, min(1, level))))
        needsDisplay = true
    }

    func reset() {
        fading = false
        levels = Array(repeating: 0, count: levels.count)
        needsDisplay = true
    }

    /// 録音が終わったらバーを静かに落とす
    func fadeOut() {
        fading = true
        levels = levels.map { $0 * 0.25 }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let barWidth: CGFloat = 2
        let gap: CGFloat = (bounds.width - CGFloat(levels.count) * barWidth) / CGFloat(max(levels.count - 1, 1))
        let color: NSColor = fading ? .tertiaryLabelColor : .systemRed
        color.setFill()
        for (index, level) in levels.enumerated() {
            let height = max(2, level * bounds.height)
            let x = CGFloat(index) * (barWidth + gap)
            let rect = NSRect(x: x, y: (bounds.height - height) / 2, width: barWidth, height: height)
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }
    }
}
