#if os(iOS)
// EditorToolbarUIView — 底部操作面板 UIKit 版（UIA-036/040 立，UIA-043 视觉改版，ADR-0024）
//
// UIA-043（传哲 2026-10-15 拍板）：
//   * **撤销/重做迁出本栏** → 传输条（与播放、时间码同栏）；本栏只留工具位，与对标 App 一致；
//   * 高度 58 → 84、图标 16 → 22、图标/标签间距 2 → 6（现状压扁是「丑」的第 3 条）；
//   * 去掉 `makeSpacer()` 硬顶开造成的空洞，一级条 6 位**等宽铺满**；
//   * 配色转对标 App 单色系（可用纯白 / 禁用低透白），蓝色 accent 在本页停用。
//
// UIA-040 分级（RESEARCH-008 范式①⑤：单焦点 + 抽屉，无常驻属性栏）：
//   * primary     —— 一级工具位：撤销/重做（左）+ 媒体/画中画/音频/文字/特效。
//                     音频/文字/特效不再是死置灰 —— 点击展开**二级替换条**；
//   * clipSelected —— 选中片段的整体替换条（范式⑤）：返回/分割/删除 + 音量/变速
//                     占位（能力未就绪不伪装可用，RESEARCH-010 空壳清单的分级化）；
//   * drawer(...) —— 音频/文字/特效/比例的二级替换条；比例是真实能力（setCanvas），
//                     其余为入口形状占位。
// 模式由 EditorViewModel.toolbarMode 驱动（UI 状态单一真源），本视图只渲染。

import UIKit
import SnapKit
import SharedUI  // 基座：Theme（ADR-0031）

@MainActor
final class EditorToolbarUIView: UIView {
    // ⚠️ UIA-043：撤销/重做的出口已迁到 `EditorTransportBarView`（与播放、时间码同栏）。
    // 本栏不再持有 onUndo/onRedo —— 出口唯一，避免两处都能触发同一命令。
    var onOpenMedia: (() -> Void)?
    /// 分割选中片段于播放头处（UIA-039；靶子与可用性由 EditorViewModel 决定）。
    var onSplitSelected: (() -> Void)?
    /// 删除选中片段（UIA-039）。
    var onDeleteSelected: (() -> Void)?
    /// 展开二级抽屉（UIA-040）。
    var onOpenDrawer: ((EditorDrawerKind) -> Void)?
    /// 收起替换条（返回一级 / 选中条）。
    var onClosePanel: (() -> Void)?
    /// 画布比例（UIA-040；比例替换条的真实出口）。
    var onSetCanvas: ((Int32, Int32) -> Void)?
    /// 新增画中画轨（UIA-040 多轨操作入口）。
    var onAddOverlayTrack: (() -> Void)?

    private var stack: UIStackView!
    /// UIA-043：底栏顶部发丝线（唯一分隔手段，不用底色差 —— 三区同底连成一体）。
    private let hairline = UIView()
    private var mode: EditorToolbarMode = .primary

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = EditorChromePalette.chromeBackground.uiColor
        hairline.backgroundColor = EditorChromePalette.chromeHairline.uiColor
        addSubview(hairline)

        stack = UIStackView(arrangedSubviews: [])
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .fill
        addSubview(stack)

        // UIA-042 / ADR-0041：SnapKit DSL（自动 translatesAutoresizingMaskIntoConstraints = false）。
        hairline.snp.makeConstraints {
            $0.leading.trailing.top.equalToSuperview()
            $0.height.equalTo(0.5)
        }
        stack.snp.makeConstraints {
            $0.leading.equalToSuperview().offset(EditorChrome.toolbarHorizontalInset)
            $0.trailing.equalToSuperview().offset(-EditorChrome.toolbarHorizontalInset)
            $0.top.equalToSuperview().offset(2)
            $0.bottom.equalToSuperview().offset(-2)
        }
        rebuildStack()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未支持（代码装配）") }

    // MARK: - 模式灌入（VM $toolbarMode 驱动）

    func setMode(_ newMode: EditorToolbarMode) {
        guard newMode != mode else { return }
        mode = newMode
        rebuildStack()
    }

    /// 按模式整体重建按钮组（条目 ≤ 8，重建成本可忽略；替换条本来就是整条换）。
    private func rebuildStack() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        switch mode {
        case .primary:
            // UIA-043：撤销/重做已迁到传输条，本栏 6 个工具位等宽铺满（无 spacer）。
            let media = toolButton(icon: "film.stack", label: "媒体", enabled: true) { [weak self] in self?.onOpenMedia?() }
            // 画中画（UIA-040）：新增一条视频轨 —— 多轨操作的入口。
            let pip = toolButton(icon: "square.on.square", label: "画中画", enabled: true) { [weak self] in self?.onAddOverlayTrack?() }
            let audio = toolButton(icon: "music.note", label: "音频", enabled: true) { [weak self] in self?.onOpenDrawer?(.audio) }
            let text = toolButton(icon: "textformat", label: "文字", enabled: true) { [weak self] in self?.onOpenDrawer?(.text) }
            let fx = toolButton(icon: "sparkles", label: "特效", enabled: true) { [weak self] in self?.onOpenDrawer?(.effects) }
            // 比例（UIA-040）：画布抽屉入口（真实能力 setCanvas）。
            let ratio = toolButton(icon: "aspect.ratio", label: "比例", enabled: true) { [weak self] in self?.onOpenDrawer?(.ratio) }
            stack.addArrangedSubviews([media, pip, audio, text, fx, ratio])

        case .clipSelected:
            let back = toolButton(icon: "chevron.down", label: "返回", enabled: true) { [weak self] in self?.onClosePanel?() }
            let split = toolButton(icon: "scissors", label: "分割", enabled: false) { [weak self] in self?.onSplitSelected?() }
            let delete = toolButton(icon: "trash", label: "删除", enabled: false) { [weak self] in self?.onDeleteSelected?() }
            // 占位：MODEL-003 属性系统落地后接真（音量/变速）。
            let volume = toolButton(icon: "speaker.wave.2", label: "音量", enabled: false) {}
            let speed = toolButton(icon: "speedometer", label: "变速", enabled: false) {}
            stack.addArrangedSubviews([back, split, delete, makeSpacer(), volume, speed])

        case .drawer(.ratio):
            let back = toolButton(icon: "chevron.down", label: "返回", enabled: true) { [weak self] in self?.onClosePanel?() }
            // 比例是真实能力：setCanvas（宽高只是比例语义，渲染目标跟随）。
            let ratio169 = toolButton(icon: "rectangle.portrait", label: "9:16", enabled: true) { [weak self] in self?.onSetCanvas?(1080, 1920) }
            let ratio916 = toolButton(icon: "rectangle.landscape", label: "16:9", enabled: true) { [weak self] in self?.onSetCanvas?(1920, 1080) }
            let ratio11 = toolButton(icon: "square", label: "1:1", enabled: true) { [weak self] in self?.onSetCanvas?(1080, 1080) }
            let ratio43 = toolButton(icon: "rectangle", label: "4:3", enabled: true) { [weak self] in self?.onSetCanvas?(1440, 1080) }
            let ratio34 = toolButton(icon: "rectangle", label: "3:4", enabled: true) { [weak self] in self?.onSetCanvas?(1080, 1440) }
            stack.addArrangedSubviews([back, makeSpacer(), ratio169, ratio916, ratio11, ratio43, ratio34])

        case .drawer(.audio):
            let back = toolButton(icon: "chevron.down", label: "返回", enabled: true) { [weak self] in self?.onClosePanel?() }
            let music = toolButton(icon: "music.quarternote.3", label: "音乐", enabled: false) {}
            let sfx = toolButton(icon: "waveform", label: "音效", enabled: false) {}
            let record = toolButton(icon: "mic", label: "录音", enabled: false) {}
            let extract = toolButton(icon: "arrow.down.doc", label: "提取", enabled: false) {}
            stack.addArrangedSubviews([back, makeSpacer(), music, sfx, record, extract])

        case .drawer(.text):
            let back = toolButton(icon: "chevron.down", label: "返回", enabled: true) { [weak self] in self?.onClosePanel?() }
            let newText = toolButton(icon: "plus.rectangle.on.rectangle", label: "新建文字", enabled: false) {}
            let caption = toolButton(icon: "captions.bubble", label: "识别字幕", enabled: false) {}
            let sticker = toolButton(icon: "character.book.closed", label: "花字", enabled: false) {}
            stack.addArrangedSubviews([back, makeSpacer(), newText, caption, sticker])

        case .drawer(.effects):
            let back = toolButton(icon: "chevron.down", label: "返回", enabled: true) { [weak self] in self?.onClosePanel?() }
            let scene = toolButton(icon: "wand.and.stars", label: "画面特效", enabled: false) {}
            let person = toolButton(icon: "person.crop.rectangle", label: "人物特效", enabled: false) {}
            let filter = toolButton(icon: "camera.filters", label: "滤镜", enabled: false) {}
            stack.addArrangedSubviews([back, makeSpacer(), scene, person, filter])
        }
    }

    private func makeSpacer() -> UIView {
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return spacer
    }

    /// 图标+文字竖排工具位（单手拇指目标，对照 SwiftUI 版 toolbarButton）。
    /// UIA-043 尺寸阶梯：图标 22 / 标签 10 / 间距 6（底栏 84pt 内不再压扁）。
    private func toolButton(icon: String, label: String, enabled: Bool,
                            action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: icon)
        config.imagePlacement = .top
        config.imagePadding = EditorChrome.toolbarIconLabelSpacing
        config.title = label
        // 单色系：可用纯白，禁用低透白（不再有彩色主色）。
        config.baseForegroundColor = enabled ? EditorChromePalette.chromeGlyph.uiColor
                                             : EditorChromePalette.chromeGlyphDisabled.uiColor
        config.preferredSymbolConfigurationForImage =
            UIImage.SymbolConfiguration(pointSize: EditorChrome.toolbarIconPointSize,
                                        weight: .medium)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attr in
            var container = attr
            container.font = .systemFont(ofSize: EditorChrome.toolbarLabelFontSize)
            return container
        }
        let button = UIButton(configuration: config, primaryAction: UIAction(handler: { _ in action() }))
        button.isEnabled = enabled
        return button
    }

    // 以下可用性只在 clipSelected 条上有意义（其余模式下按钮随整条重建）。
    func setSplitEnabled(_ enabled: Bool) { setButton("分割", enabled: enabled) }
    func setDeleteEnabled(_ enabled: Bool) { setButton("删除", enabled: enabled) }

    /// 按标签找按钮改可用性（条目少，线性找；重建后引用失效问题由此规避）。
    /// ⚠️ Configuration 风格的标题在 layout 前不回填 titleLabel.text —— 判 configuration.title。
    private func setButton(_ label: String, enabled: Bool) {
        for case let button as UIButton in stack.arrangedSubviews
        where button.configuration?.title == label {
            button.isEnabled = enabled
            // Configuration 风格不会因 isEnabled 自动换色 —— 必须显式改前景色，
            // 否则「置灰」只有命中区失效、看起来仍是可点的白（假状态）。
            button.configuration?.baseForegroundColor =
                enabled ? EditorChromePalette.chromeGlyph.uiColor
                        : EditorChromePalette.chromeGlyphDisabled.uiColor
        }
    }
}

private extension UIStackView {
    func addArrangedSubviews(_ views: [UIView]) { views.forEach(addArrangedSubview) }
}
#endif
