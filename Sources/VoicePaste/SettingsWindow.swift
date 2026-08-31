import AppKit
import Foundation
import VoicePasteCore

/// ショートカットキーなどを画面から設定する窓。
/// 保存するとアプリを再起動せずにその場でホットキーを付け替える。
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var config: Config

    private let toggleRecorder = ShortcutRecorderView()
    private let pasteLastRecorder = ShortcutRecorderView()
    private let editRecorder = ShortcutRecorderView()
    private let warningLabel = NSTextField(labelWithString: "")
    private let hudCheckbox = NSButton(checkboxWithTitle: "録音中に画面下へポップアップを出す", target: nil, action: nil)
    private let captionCheckbox = NSButton(checkboxWithTitle: "喋っている内容をその場で文字にして見せる", target: nil, action: nil)
    private let localePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let apiKeyField = NSSecureTextField(frame: .zero)
    private let cleanupCheckbox = NSButton(checkboxWithTitle: "認識したあと句読点を整える", target: nil, action: nil)
    private let micPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// micPopup の各項目に対応する設定値（`builtin` / `system` / 機器のUID）
    private var micChoices: [String] = []

    /// 保存が押されたとき。呼び出し側で config を保存してホットキーを付け替える
    var onSave: ((Config) -> Void)?

    private static let locales: [(title: String, identifier: String)] = [
        ("日本語", "ja-JP"),
        ("English", "en-US"),
    ]

    init(config: Config) {
        self.config = config
        super.init()
    }

    func show(config: Config) {
        self.config = config
        let window = self.window ?? makeWindow()
        loadValues()
        // メニューバー常駐アプリなので、明示的に前面に出さないと入力できない
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        // 開いた瞬間に先頭のショートカット欄がキー入力待ちになると、
        // 現在の設定が見えないうえに Enter での保存も奪われる。明示的に外す
        window.makeFirstResponder(nil)
    }

    // MARK: - 値の出し入れ

    private func loadValues() {
        toggleRecorder.value = config.hotkey_toggle
        pasteLastRecorder.value = config.hotkey_paste_last
        editRecorder.value = config.hotkey_edit
        hudCheckbox.state = config.hud_enabled ? .on : .off
        captionCheckbox.state = config.live_caption_enabled ? .on : .off
        apiKeyField.stringValue = config.groq_api_key
        cleanupCheckbox.state = config.cleanup_enabled ? .on : .off
        let index = Self.locales.firstIndex { $0.identifier == config.live_caption_locale } ?? 0
        localePopup.selectItem(at: index)
        reloadMicChoices()
        updateWarning()
    }

    /// マイクの一覧は設定画面を開くたびに取り直す（AirPodsのつなぎ外しで変わるため）
    private func reloadMicChoices() {
        let devices = AudioInputDevices.list().map(\.info)
        let systemName = devices.first { $0.isSystemDefault }?.name ?? "不明"
        var titles = ["Macの内蔵マイク（既定）", "macOSのサウンド設定に従う（いま: \(systemName)）"]
        var choices = [InputDeviceSelection.builtIn, InputDeviceSelection.followSystem]
        for device in devices where !device.isBuiltIn {
            titles.append(device.name)
            choices.append(device.uid)
        }
        let current = config.input_device.isEmpty ? InputDeviceSelection.builtIn : config.input_device
        if !choices.contains(current) {
            titles.append("設定済みのマイク（いま未接続）")
            choices.append(current)
        }
        micPopup.removeAllItems()
        micPopup.addItems(withTitles: titles)
        micChoices = choices
        micPopup.selectItem(at: choices.firstIndex(of: current) ?? 0)
    }

    private func collectValues() -> Config {
        var updated = config
        updated.hotkey_toggle = toggleRecorder.value
        updated.hotkey_paste_last = pasteLastRecorder.value
        updated.hotkey_edit = editRecorder.value
        updated.hud_enabled = hudCheckbox.state == .on
        updated.live_caption_enabled = captionCheckbox.state == .on
        updated.groq_api_key = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.cleanup_enabled = cleanupCheckbox.state == .on
        let index = localePopup.indexOfSelectedItem
        if index >= 0, index < Self.locales.count {
            updated.live_caption_locale = Self.locales[index].identifier
        }
        let micIndex = micPopup.indexOfSelectedItem
        if micIndex >= 0, micIndex < micChoices.count {
            updated.input_device = micChoices[micIndex]
        }
        return updated
    }

    @objc private func valueChanged() {
        updateWarning()
    }

    private func updateWarning() {
        if let duplicate = collectValues().duplicatedHotkey {
            warningLabel.stringValue = "\(duplicate) が2つの機能に重なっています。別のキーにしてください"
            warningLabel.textColor = .systemRed
        } else {
            warningLabel.stringValue = "キーの欄をクリックしてから、使いたいキーを押してください"
            warningLabel.textColor = .tertiaryLabelColor
        }
    }

    @objc private func saveClicked() {
        let updated = collectValues()
        if let duplicate = updated.duplicatedHotkey {
            warningLabel.stringValue = "\(duplicate) が重なっているので保存できません"
            warningLabel.textColor = .systemRed
            NSSound.beep()
            return
        }
        onSave?(updated)
        config = updated
        window?.close()
    }

    @objc private func cancelClicked() {
        window?.close()
    }

    // MARK: - 画面の組み立て

    private func makeWindow() -> NSWindow {
        let contentWidth: CGFloat = 540
        let contentHeight: CGFloat = 560
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoicePaste の設定"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let content = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight))

        let labelX: CGFloat = 24
        let labelWidth: CGFloat = 230
        let controlX: CGFloat = 266
        let controlWidth: CGFloat = 250

        func section(_ title: String, y: CGFloat) {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.frame = NSRect(x: labelX, y: y, width: contentWidth - labelX * 2, height: 18)
            content.addSubview(label)
        }

        func row(_ title: String, control: NSView, y: CGFloat, height: CGFloat) {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .labelColor
            label.alignment = .right
            label.frame = NSRect(x: labelX, y: y + (height - 16) / 2, width: labelWidth, height: 16)
            content.addSubview(label)
            control.frame = NSRect(x: controlX, y: y, width: controlWidth, height: height)
            content.addSubview(control)
        }

        section("ショートカットキー", y: 518)
        row("音声入力（開始・停止）", control: toggleRecorder, y: 486, height: 26)
        row("直前の内容をもう一度貼る", control: pasteLastRecorder, y: 452, height: 26)
        row("選んだ文章を音声で書き換える", control: editRecorder, y: 418, height: 26)

        warningLabel.font = .systemFont(ofSize: 11)
        // 注意書きは日本語だと横に長くなるので、右カラムではなく本文幅いっぱいを使う
        warningLabel.frame = NSRect(x: labelX, y: 396, width: contentWidth - labelX * 2, height: 16)
        warningLabel.alignment = .right
        warningLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(warningLabel)

        section("画面の表示", y: 358)
        hudCheckbox.frame = NSRect(x: controlX, y: 330, width: controlWidth + 20, height: 20)
        hudCheckbox.font = .systemFont(ofSize: 12)
        content.addSubview(hudCheckbox)
        captionCheckbox.frame = NSRect(x: controlX, y: 306, width: controlWidth + 20, height: 20)
        captionCheckbox.font = .systemFont(ofSize: 12)
        content.addSubview(captionCheckbox)

        localePopup.removeAllItems()
        localePopup.addItems(withTitles: Self.locales.map(\.title))
        row("その場で見せる文字の言語", control: localePopup, y: 272, height: 25)

        let localeNote = NSTextField(labelWithString: "確定する文章はGroqが言語を自動判定するので、ここは表示用です")
        localeNote.font = .systemFont(ofSize: 11)
        localeNote.textColor = .tertiaryLabelColor
        localeNote.frame = NSRect(x: labelX, y: 252, width: contentWidth - labelX * 2, height: 16)
        localeNote.alignment = .right
        localeNote.lineBreakMode = .byTruncatingTail
        content.addSubview(localeNote)

        section("音声認識", y: 214)
        apiKeyField.placeholderString = "gsk_..."
        apiKeyField.font = .systemFont(ofSize: 12)
        row("Groq APIキー", control: apiKeyField, y: 182, height: 24)
        cleanupCheckbox.frame = NSRect(x: controlX, y: 154, width: controlWidth + 20, height: 20)
        cleanupCheckbox.font = .systemFont(ofSize: 12)
        content.addSubview(cleanupCheckbox)

        section("マイク", y: 118)
        row("録音に使うマイク", control: micPopup, y: 86, height: 25)
        let micNote = NSTextField(labelWithString: "AirPodsなどをつないでいても、ここで選んだマイクで録音します")
        micNote.font = .systemFont(ofSize: 11)
        micNote.textColor = .tertiaryLabelColor
        micNote.frame = NSRect(x: labelX, y: 64, width: contentWidth - labelX * 2, height: 16)
        micNote.alignment = .right
        micNote.lineBreakMode = .byTruncatingTail
        content.addSubview(micNote)

        let saveButton = NSButton(title: "保存", target: self, action: #selector(saveClicked))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.frame = NSRect(x: contentWidth - 24 - 96, y: 18, width: 96, height: 30)
        content.addSubview(saveButton)

        let cancelButton = NSButton(title: "キャンセル", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.frame = NSRect(x: contentWidth - 24 - 96 - 8 - 110, y: 18, width: 110, height: 30)
        content.addSubview(cancelButton)

        for checkbox in [hudCheckbox, captionCheckbox, cleanupCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(valueChanged)
        }
        for recorder in [toggleRecorder, pasteLastRecorder, editRecorder] {
            recorder.onChange = { [weak self] _ in self?.updateWarning() }
        }

        window.contentView = content
        self.window = window
        return window
    }
}

/// クリックしてからキーを押すと、その組み合わせを取り込む欄。
/// 修飾キーなし（例: A だけ）は通常のキー入力を全部奪ってしまうので受け付けない。
final class ShortcutRecorderView: NSView {
    var value: String = "" {
        didSet { needsDisplay = true }
    }
    var onChange: ((String) -> Void)?

    private var isRecording = false {
        didSet { needsDisplay = true }
    }
    private var hint: String?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        isRecording = true
        hint = nil
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        hint = nil
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    /// ⌘付きの組み合わせは keyDown より先にここへ来るので、記録中は横取りする
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return false }
        return capture(event)
    }

    override func keyDown(with event: NSEvent) {
        if !capture(event) { super.keyDown(with: event) }
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return }
        needsDisplay = true
    }

    private func capture(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        let keyCode = UInt32(event.keyCode)

        // Esc は記録の取り消し
        if keyCode == 53, !event.modifierFlags.contains(.command) {
            window?.makeFirstResponder(nil)
            return true
        }

        var carbon: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { carbon |= HotKeySpec.cmd }
        if flags.contains(.control) { carbon |= HotKeySpec.control }
        if flags.contains(.option) { carbon |= HotKeySpec.option }
        if flags.contains(.shift) { carbon |= HotKeySpec.shift }

        let spec = HotKeySpec(keyCode: keyCode, carbonModifiers: carbon)
        guard let configString = spec.configString else {
            hint = "そのキーは使えません"
            NSSound.beep()
            needsDisplay = true
            return true
        }
        guard spec.hasModifier else {
            hint = "⌘ / ⌃ / ⌥ と組み合わせてください"
            NSSound.beep()
            needsDisplay = true
            return true
        }

        value = configString
        onChange?(configString)
        window?.makeFirstResponder(nil)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let text: String
        let color: NSColor
        if let hint {
            text = hint
            color = .systemRed
        } else if isRecording {
            text = "キーを押してください（Esc で中止）"
            color = .secondaryLabelColor
        } else {
            text = HotKeySpec.symbolString(for: value)
            color = .labelColor
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: isRecording || hint != nil ? 11 : 13, weight: .medium),
            .foregroundColor: color,
        ]
        let size = text.size(withAttributes: attributes)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        text.draw(at: origin, withAttributes: attributes)
    }
}
