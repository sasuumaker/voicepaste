# VoicePaste

**English** | [日本語](#voicepaste-日本語)

A menu-bar dictation app for macOS. Press a hotkey, talk, and the text lands at your cursor.

Built as a self-hosted replacement for paid dictation apps. Recognition runs on
[Groq](https://console.groq.com) `whisper-large-v3-turbo`, whose free tier covers roughly
1,000 dictations per day — so day-to-day use costs nothing.

## What it does

| | |
|---|---|
| **Dictate** | Hotkey to start, hotkey again to stop. The result is pasted at the cursor. |
| **Live caption** | A panel at the bottom of the screen shows an input-level meter and what you are saying, as you say it. It keeps growing instead of scrolling away, so you can read back the whole utterance. |
| **Edit by voice** | Select text, press the edit hotkey, and say an instruction ("make this a list", "translate to English"). The selection is replaced with the result. |
| **Paste again** | If you dictated while nothing was focused, focus the right field and press the re-paste hotkey. |
| **Settings window** | Click a shortcut field and press the keys you want. Saving re-binds immediately — no restart. |

Japanese and English are detected automatically; no language switch to flip.

## Design notes worth knowing

- **The live caption never leaves your Mac.** It uses Apple's on-device speech recognition purely
  for display. If a language cannot be recognised on-device, the caption is skipped rather than
  sending audio to a server. The text that actually gets pasted comes from Groq.
- **The caption panel never takes keyboard focus.** Paste targets the app you were typing in, so the
  panel is a non-activating, click-through window.
- **Pasting waits for your fingers.** A synthesised `⌘V` is merged with the modifier keys you are
  physically holding, so firing it while `⌃⌘V` is still down delivers `⌃⌘V` and pastes nothing.
  VoicePaste waits (briefly) for the modifiers to come up first.

`SPEC.md` documents the internals, including the failure modes above and how they were diagnosed.
It is written in Japanese.

## Requirements

- macOS 13 or later (developed on macOS 26, Apple Silicon)
- Command Line Tools for Xcode (a full Xcode install is not required)
- A Groq API key — free at [console.groq.com](https://console.groq.com)

## Install

```bash
git clone https://github.com/sasuumaker/voicepaste.git
cd voicepaste
./setup-signing.sh   # once: creates a fixed self-signed certificate
./build.sh           # produces build/VoicePaste.app
open build/VoicePaste.app
```

Then open the menu-bar icon → **設定…** (Settings) and paste your Groq API key.

`setup-signing.sh` exists because an ad-hoc signature changes on every rebuild, and macOS then treats
the app as a new one and drops its accessibility permission. A fixed certificate keeps the permission
across rebuilds. It creates its own keychain and never touches your login keychain.

### Permissions

| Permission | Used for | Without it |
|---|---|---|
| Microphone | Recording | Nothing is recorded |
| Accessibility | Sending `⌘V` | Text still reaches the clipboard; paste manually |
| Speech Recognition | Live caption only | Recording and pasting work; the caption is skipped |

## Configuration

Settings live in `~/.config/voicepaste/config.json` — **outside the repository**, so your API key is
never at risk of being committed. The settings window writes the same file.

```json
{
  "groq_api_key": "",
  "model": "whisper-large-v3-turbo",
  "hotkey_toggle": "cmd+slash",
  "hotkey_paste_last": "ctrl+cmd+v",
  "hotkey_edit": "ctrl+slash",
  "cleanup_enabled": true,
  "cleanup_model": "llama-3.3-70b-versatile",
  "hud_enabled": true,
  "live_caption_enabled": true,
  "live_caption_locale": "ja-JP"
}
```

The key is read from `groq_api_key` first, then the `GROQ_API_KEY` environment variable.
`cleanup_enabled` runs the transcript through an LLM to add punctuation and drop fillers; turn it off
to paste exactly what Whisper heard. `live_caption_locale` only affects the on-screen caption — the
pasted text always comes from Whisper's own language detection.

## Cost

Groq's free tier allows 2,000 transcription requests and 1,000 chat requests per day. One dictation
uses one of each, so the chat limit is the binding one at roughly 1,000 dictations per day.
Going over means requests are rejected, not billed.

On a paid plan the same usage is small: transcription is billed per hour of audio, and at around
30 dictations a day the total lands near a few tens of cents per month.

## Development

```bash
swift build
swift run VoicePasteTests   # unit tests (no XCTest dependency; CLT-only environments)
swift run VoicePasteE2E     # end-to-end, hits the real Groq API, needs a key
```

Tests avoid XCTest so they run without a full Xcode install. The end-to-end test synthesises speech
with `say`, so the tricky paths (voice instructions, homophone mistakes) can be exercised without a
microphone.

## License

MIT — see `LICENSE`.

---

# VoicePaste （日本語）

[English](#voicepaste) | **日本語**

macOSのメニューバーに常駐する音声入力アプリです。ショートカットキーを押して喋ると、カーソル位置に文章が入ります。

有料の音声入力アプリを自作で置き換えるために作りました。認識は [Groq](https://console.groq.com) の
`whisper-large-v3-turbo` を使います。無料枠だけで1日1,000回ほど喋れるので、日常的な利用では費用がかかりません。

## できること

| | |
|---|---|
| **音声入力** | ショートカットで開始、もう一度押して停止。カーソル位置に貼り付きます |
| **リアルタイム字幕** | 画面下のパネルに音量メーターと、喋っている内容がその場で出ます。流れて消えるのではなく溜まって伸びるので、話した全体を読み返せます |
| **音声で書き換え** | 文章を選んで編集用のキーを押し、「これをリストにして」のように指示すると、選んだ部分が結果に置き換わります |
| **もう一度貼る** | どこにもフォーカスしていない状態で喋ってしまったとき、入れたい場所を選んでから押し直せます |
| **設定画面** | 欄をクリックして使いたいキーを押すだけ。保存すると再起動なしで切り替わります |

日本語と英語は自動で判別されるので、言語の切り替え操作は要りません。

## 設計上のポイント

- **字幕はMacの外に出ません。** 画面表示にはApple内蔵のオンデバイス認識だけを使い、端末内で認識できない
  言語のときは、サーバーへ音声を送らずに字幕を出さない判断をします。実際に貼り付ける文章はGroqが作ります
- **字幕パネルはキーボードのフォーカスを奪いません。** 貼り付け先は「さっきまで入力していたアプリ」なので、
  パネルは非アクティブ・クリック透過の窓にしてあります
- **貼り付けは指が離れるのを待ちます。** 合成した `⌘V` は実際に押されているキーと合わさるため、
  `⌃⌘V` を押したまま送ると相手には `⌃⌘V` として届き、何も貼られません

内部の詳細と、上記のような不具合をどう切り分けたかは `SPEC.md` に書いてあります。

## 必要なもの

- macOS 13以降（開発環境は macOS 26 / Apple Silicon）
- Xcodeのコマンドラインツール（Xcode本体は不要）
- Groq の APIキー（[console.groq.com](https://console.groq.com) で無料）

## 導入

```bash
git clone https://github.com/sasuumaker/voicepaste.git
cd voicepaste
./setup-signing.sh   # 初回だけ: 固定の自己署名証明書を作る
./build.sh           # build/VoicePaste.app ができる
open build/VoicePaste.app
```

そのあとメニューバーのアイコン →「設定…」でGroqのAPIキーを入れてください。

`setup-signing.sh` があるのは、署名が毎回変わるとmacOSが別アプリとみなして、アクセシビリティの許可が
そのたびに外れるからです。固定の証明書を使うと、作り直しても許可が維持されます。専用のキーチェーンを
作るので、ログインキーチェーンには触れません。

### 必要な権限

| 権限 | 用途 | 無いとどうなるか |
|---|---|---|
| マイク | 録音 | 何も録音されません |
| アクセシビリティ | `⌘V` の送信 | クリップボードには入るので、手動で貼れます |
| 音声認識 | リアルタイム字幕のみ | 録音と貼り付けは動き、字幕だけ出ません |

## 設定

設定は `~/.config/voicepaste/config.json` にあります。**リポジトリの外**なので、APIキーを
誤ってコミットする心配はありません。設定画面も同じファイルを書き換えます。

```json
{
  "groq_api_key": "",
  "model": "whisper-large-v3-turbo",
  "hotkey_toggle": "cmd+slash",
  "hotkey_paste_last": "ctrl+cmd+v",
  "hotkey_edit": "ctrl+slash",
  "cleanup_enabled": true,
  "cleanup_model": "llama-3.3-70b-versatile",
  "hud_enabled": true,
  "live_caption_enabled": true,
  "live_caption_locale": "ja-JP"
}
```

APIキーは `groq_api_key` を先に見て、無ければ環境変数 `GROQ_API_KEY` を使います。
`cleanup_enabled` は、認識結果をLLMに通して句読点を補い、フィラーを除去する設定です。
オフにすると、認識したままの文章が貼られます。`live_caption_locale` は画面に出す字幕だけに効く設定で、
貼り付ける文章は常にWhisperの言語自動判定に従います。

## 費用

Groqの無料枠は、認識が1日2,000回、整形が1日1,000回です。音声入力1回で両方を1回ずつ使うので、
厳しい方の整形側で **1日およそ1,000回** が上限になります。超えた場合は課金ではなく、
リクエストが一時的に弾かれるだけです。

有料プランでも金額は小さく、認識は音声1時間あたりの課金なので、1日30回ほど使う程度なら
月に数十セント規模に収まります。

## 開発

```bash
swift build
swift run VoicePasteTests   # ユニットテスト（XCTest非依存。CLTのみの環境向け）
swift run VoicePasteE2E     # 実際のGroq APIを叩くE2Eテスト。APIキーが要ります
```

Xcode本体が無くても動くようにXCTestを使っていません。E2Eテストは `say` で音声を合成するので、
音声指示や同音異義語の誤変換といった厄介な経路を、マイクなしで検証できます。

## ライセンス

MIT — `LICENSE` を参照してください。
