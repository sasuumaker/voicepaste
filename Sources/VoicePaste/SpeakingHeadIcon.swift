import AppKit

/// メニューバーのアイコン: 右向きの横顔で口を開け、口の前に声を表す弧が2本ある形（絵文字の 🗣 と同じ形）。
///
/// 以前の `mic`（SF Symbols のマイク）は、macOS の入力切り替えの印と見分けがつかなかった（2026-10-25 本人）。
/// SF Symbols に横顔で喋っている形が無いので、ここで描く。
///
/// 色はボタンの `contentTintColor` では付けない。今の macOS のメニューバーはテンプレート画像に付けた色を無視し、
/// 学習用に残すをオンにしても緑にならなかった（2026-10-25 本人の画面で確認）。緑・赤は最初からその色で描いた
/// 画像（テンプレートでない）にする。色が出ない場合にも見分けられるよう、学習用に残すの間は右上に丸を付ける
enum SpeakingHeadIcon {
    enum Style {
        /// 待機中・学習用に残すがオフ。テンプレート画像なので、メニューバーの明暗に合わせて色が変わる
        case idle
        /// 待機中・学習用に残すがオン。緑で、右上に丸
        case training
        /// 録音中。赤
        case recording
    }

    static func image(_ style: Style) -> NSImage {
        switch style {
        case .idle: return idleImage
        case .training: return trainingImage
        case .recording: return recordingImage
        }
    }

    private static let idleImage = make(color: .black, badge: false, template: true)
    private static let trainingImage = make(color: .systemGreen, badge: true, template: false)
    private static let recordingImage = make(color: .systemRed, badge: false, template: false)

    private static func make(color: NSColor, badge: Bool, template: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { box in
            draw(in: box, color: color, badge: badge)
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = "VoicePaste"
        return image
    }

    /// 18×18 の座標で描いた形を、渡された大きさに合わせて描く
    static func draw(in box: NSRect, color: NSColor, badge: Bool) {
        let s = box.width / 18
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: box.minX + x * s, y: box.minY + y * s) }
        color.set()

        let head = NSBezierPath()
        head.move(to: p(2.6, 0.8))
        head.line(to: p(2.6, 4.8))  // 首の後ろ
        head.curve(to: p(1.0, 10.6), controlPoint1: p(1.3, 6.3), controlPoint2: p(1.0, 8.6))
        head.curve(to: p(6.8, 16.8), controlPoint1: p(1.0, 14.2), controlPoint2: p(3.6, 16.8))
        head.curve(to: p(12.2, 12.2), controlPoint1: p(10.2, 16.8), controlPoint2: p(12.2, 14.8))
        head.line(to: p(12.2, 11.2))
        head.line(to: p(13.9, 9.0))  // 鼻
        head.line(to: p(12.4, 8.6))
        head.line(to: p(12.4, 8.1))
        head.line(to: p(11.0, 7.4))  // 開いた口（内側への切れ込み）
        head.line(to: p(12.4, 6.7))
        head.line(to: p(12.4, 5.9))
        head.curve(to: p(10.6, 4.0), controlPoint1: p(12.4, 4.7), controlPoint2: p(11.7, 4.0))  // あご
        head.line(to: p(8.8, 4.0))
        head.line(to: p(8.8, 0.8))  // 首の前
        head.close()
        head.fill()

        for radius in [2.6, 4.6] as [CGFloat] {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: p(12.6, 7.4), radius: radius * s, startAngle: -38, endAngle: 38)
            arc.lineWidth = 1.35 * s
            arc.lineCapStyle = .round
            arc.stroke()
        }

        if badge {
            // 右上の空いている所に丸（頭の上・弧の上で、形に重ならない）
            NSBezierPath(ovalIn: NSRect(x: box.minX + 13.4 * s, y: box.minY + 13.4 * s, width: 4.2 * s, height: 4.2 * s)).fill()
        }
    }
}
