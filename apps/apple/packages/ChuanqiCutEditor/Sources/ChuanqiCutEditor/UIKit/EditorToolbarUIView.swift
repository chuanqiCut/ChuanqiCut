#if os(iOS)
// EditorToolbarUIView — 底部工具栏 UIKit 版（UIA-036，ADR-0024）
//
// 形状对照 SwiftUI 版 EditorBottomToolbar（UIA-032 已验收）：撤销/重做（左）
// + 一级工具位（媒体/音频/文字/特效，图标+文字竖排）。
// 「媒体」开抽屉（回调到 SwiftUI 的 MediaSheet sheet）；音频/文字/特效置灰占位
// —— 二级替换条在各自能力实装时引入（UIA-036 范围：一级条形状）。

import UIKit
import SharedUI  // 基座：Theme（ADR-0031）

@MainActor
final class EditorToolbarUIView: UIView {
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onOpenMedia: (() -> Void)?

    private var undoButton: UIButton!
    private var redoButton: UIButton!
    private var mediaButton: UIButton!

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(Theme.toolbarBackground)

        let stack = UIStackView(arrangedSubviews: [])
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        undoButton = toolButton(icon: "arrow.uturn.backward", label: "撤销", enabled: false) { [weak self] in self?.onUndo?() }
        redoButton = toolButton(icon: "arrow.uturn.forward", label: "重做", enabled: false) { [weak self] in self?.onRedo?() }
        let spacer = UIView()
        mediaButton = toolButton(icon: "film.stack", label: "媒体", enabled: true) { [weak self] in self?.onOpenMedia?() }
        let audio = toolButton(icon: "music.note", label: "音频", enabled: false) {}
        let text = toolButton(icon: "textformat", label: "文字", enabled: false) {}
        let fx = toolButton(icon: "sparkles", label: "特效", enabled: false) {}
        stack.addArrangedSubviews([undoButton, redoButton, spacer, mediaButton, audio, text, fx])
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未支持（代码装配）") }

    /// 图标+文字竖排工具位（单手拇指目标，对照 SwiftUI 版 toolbarButton）。
    private func toolButton(icon: String, label: String, enabled: Bool,
                            action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: icon)
        config.imagePlacement = .top
        config.imagePadding = 2
        config.title = label
        let colors: UIColor = enabled ? UIColor(Theme.primaryText) : UIColor(Theme.tertiaryText)
        config.baseForegroundColor = colors
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 16)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attr in
            var container = attr
            container.font = .systemFont(ofSize: 10)
            return container
        }
        let button = UIButton(configuration: config, primaryAction: UIAction(handler: { _ in action() }))
        button.isEnabled = enabled
        return button
    }

    func setUndoEnabled(_ enabled: Bool) { undoButton?.isEnabled = enabled }
    func setRedoEnabled(_ enabled: Bool) { redoButton?.isEnabled = enabled }
}

private extension UIStackView {
    func addArrangedSubviews(_ views: [UIView]) { views.forEach(addArrangedSubview) }
}
#endif
