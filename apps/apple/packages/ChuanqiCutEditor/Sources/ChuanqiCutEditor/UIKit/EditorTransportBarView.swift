#if os(iOS)
// EditorTransportBarView — 播放控制条 UIKit 版（UIA-036 立，UIA-043 视觉改版）
//
// UIA-043 布局（传哲 2026-10-15 拍板「撤销/重做跟播放和时间放一栏、播放放中间」）：
//   [撤销][重做]            ▶             00:03.2 / 00:12.0
//    左（历史操作）      正中（播放/暂停）       右（时间码）
//
// UIA-043 视觉（对标 App单色系）：
//   * 撤销/重做从**底栏**迁来（底栏只留工具位，与对标 App一致）；
//   * 播放钮去掉灰圆底，改用白色字形（现状灰圆 + 小图标是「丑」的第 4 条）；
//   * 底色与时间线、底栏统一为 `chromeBackground`（三区连成一体，不再拼两条硬边）。
//
// 行为零变化：撤销/重做仍走 EditorViewModel.undo/redo（宿主翻译），
// 播放仍走 togglePlayback（红线 #5：UI 不改模型，本类只发动作）。

import UIKit
import SnapKit
import SharedUI  // 基座：Theme（ADR-0031）

@MainActor
final class EditorTransportBarView: UIView {
    /// 播放/暂停（走既有 togglePlayback，红线 #5）。
    var onTogglePlayback: (() -> Void)?
    /// 撤销（UIA-043：出口从底栏迁到本条；命令仍由宿主翻译成 VM.undo）。
    var onUndo: (() -> Void)?
    /// 重做（同上）。
    var onRedo: (() -> Void)?

    private let undoButton = UIButton(type: .system)
    private let redoButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let timecodeLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = EditorChromePalette.chromeBackground.uiColor

        historyButton(undoButton, systemName: "arrow.uturn.backward",
                      accessibilityLabel: "撤销", action: #selector(undoTapped))
        historyButton(redoButton, systemName: "arrow.uturn.forward",
                      accessibilityLabel: "重做", action: #selector(redoTapped))

        playButton.tintColor = EditorChromePalette.chromeGlyph.uiColor
        playButton.accessibilityLabel = "播放或暂停"
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        addSubview(playButton)

        timecodeLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        timecodeLabel.textColor = EditorChromePalette.chromeTimecode.uiColor
        timecodeLabel.textAlignment = .right
        timecodeLabel.text = "00:00.0 / 00:00.0"
        addSubview(timecodeLabel)

        // UIA-042 / ADR-0041：SnapKit DSL（自动 translatesAutoresizingMaskIntoConstraints = false）。
        let inset = EditorChrome.transportHorizontalInset
        let historySize = EditorChrome.transportHistorySize
        undoButton.snp.makeConstraints {
            $0.leading.equalToSuperview().offset(inset)
            $0.centerY.equalToSuperview()
            $0.width.height.equalTo(historySize)
        }
        redoButton.snp.makeConstraints {
            $0.leading.equalTo(undoButton.snp.trailing).offset(EditorChrome.transportHistorySpacing)
            $0.centerY.equalToSuperview()
            $0.width.height.equalTo(historySize)
        }
        playButton.snp.makeConstraints {
            // 水平居中（UIA-043 拍板）：与两侧历史操作/时间码互不挤压。
            $0.centerX.equalToSuperview()
            $0.centerY.equalToSuperview()
            $0.width.height.equalTo(EditorChrome.transportPlaySize)
        }
        timecodeLabel.snp.makeConstraints {
            $0.trailing.equalToSuperview().offset(-inset)
            $0.centerY.equalToSuperview()
            $0.leading.greaterThanOrEqualTo(redoButton.snp.trailing).offset(8)
        }
        setPlaying(false)
        setUndoEnabled(false)
        setRedoEnabled(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未支持（代码装配）") }

    private func historyButton(_ button: UIButton, systemName: String,
                               accessibilityLabel: String, action: Selector) {
        let image = UIImage(systemName: systemName,
                            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15,
                                                                           weight: .medium))
        button.setImage(image, for: .normal)
        button.tintColor = EditorChromePalette.chromeGlyph.uiColor
        button.accessibilityLabel = accessibilityLabel
        button.addTarget(self, action: action, for: .touchUpInside)
        addSubview(button)
    }

    @objc private func undoTapped() { onUndo?() }
    @objc private func redoTapped() { onRedo?() }
    @objc private func playTapped() { onTogglePlayback?() }

    func setPlaying(_ playing: Bool) {
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        playButton.setImage(UIImage(systemName: playing ? "pause.fill" : "play.fill",
                                    withConfiguration: config), for: .normal)
    }

    /// 空时间线：播放钮置灰 + 时间码转暗（语义同 UIA-032，颜色换单色系令牌）。
    func setEnabled(_ hasClips: Bool) {
        playButton.isEnabled = hasClips
        playButton.tintColor = hasClips ? EditorChromePalette.chromeGlyph.uiColor
                                        : EditorChromePalette.chromeGlyphDisabled.uiColor
        timecodeLabel.textColor = hasClips ? EditorChromePalette.chromeLabel.uiColor
                                           : EditorChromePalette.chromeTimecode.uiColor
    }

    func setUndoEnabled(_ enabled: Bool) {
        undoButton.isEnabled = enabled
        undoButton.tintColor = enabled ? EditorChromePalette.chromeGlyph.uiColor
                                       : EditorChromePalette.chromeGlyphDisabled.uiColor
    }

    func setRedoEnabled(_ enabled: Bool) {
        redoButton.isEnabled = enabled
        redoButton.tintColor = enabled ? EditorChromePalette.chromeGlyph.uiColor
                                       : EditorChromePalette.chromeGlyphDisabled.uiColor
    }

    func updateTimecode(current: String, duration: String) {
        let text = "\(current) / \(duration)"
        if timecodeLabel.text != text { timecodeLabel.text = text }
    }
}
#endif
