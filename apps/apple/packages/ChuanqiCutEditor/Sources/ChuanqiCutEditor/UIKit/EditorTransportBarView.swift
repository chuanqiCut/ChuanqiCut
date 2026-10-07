#if os(iOS)
// EditorTransportBarView — 播放控制条 UIKit 版（UIA-036，ADR-0024）
//
// 形状对照 SwiftUI 版 EditorTransportBar（UIA-032 已验收）：播放/暂停圆钮（32，
// accent 底、空时间线 trackFill 置灰）+ 时间码「当前 / 总时长」。
// 差异：时间码文本由 CADisplayLink 直更（UIA-034 的每帧驱动），不经 SwiftUI。

import UIKit
import SharedUI  // 基座：Theme（ADR-0031）

@MainActor
final class EditorTransportBarView: UIView {
    /// 播放/暂停（走既有 togglePlayback，红线 #5）。
    var onTogglePlayback: (() -> Void)?

    private let playButton = UIButton(type: .system)
    private let timecodeLabel = UILabel()
    private let playCircle = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(Theme.transportBackground)

        playCircle.backgroundColor = UIColor(Theme.trackFill)
        playCircle.layer.cornerRadius = 16
        playCircle.isUserInteractionEnabled = false
        playCircle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(playCircle)

        playButton.tintColor = UIColor(Theme.accentText)
        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        addSubview(playButton)

        timecodeLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        timecodeLabel.textColor = UIColor(Theme.tertiaryText)
        timecodeLabel.textAlignment = .right
        timecodeLabel.text = "0:00.0 / 0:00.0"
        timecodeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(timecodeLabel)

        NSLayoutConstraint.activate([
            playCircle.centerXAnchor.constraint(equalTo: playButton.centerXAnchor),
            playCircle.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            playCircle.widthAnchor.constraint(equalToConstant: 32),
            playCircle.heightAnchor.constraint(equalToConstant: 32),

            playButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            playButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 36),
            playButton.heightAnchor.constraint(equalToConstant: 36),

            timecodeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            timecodeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setPlaying(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未支持（代码装配）") }

    @objc private func playTapped() { onTogglePlayback?() }

    func setPlaying(_ playing: Bool) {
        playButton.setImage(UIImage(systemName: playing ? "pause.fill" : "play.fill"),
                            for: .normal)
    }

    /// 空时间线：钮置灰 + 时间码转暗（对照 SwiftUI 版）。
    func setEnabled(_ hasClips: Bool) {
        playButton.isEnabled = hasClips
        playCircle.backgroundColor = UIColor(hasClips ? Theme.accent : Theme.trackFill)
        timecodeLabel.textColor = UIColor(hasClips ? Theme.secondaryText : Theme.tertiaryText)
    }

    func updateTimecode(current: String, duration: String) {
        let text = "\(current) / \(duration)"
        if timecodeLabel.text != text { timecodeLabel.text = text }
    }
}
#endif
