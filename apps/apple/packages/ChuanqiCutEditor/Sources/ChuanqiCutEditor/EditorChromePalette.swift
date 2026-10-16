// EditorChromePalette — 编辑页「外壳」视觉常量（UIA-043：对标 App 单色系）
//
// ## 为什么单独有这个文件（与 `TimelinePalette` 同一手法，见其头部说明）
//
// 编辑页改单色系要改的是**共享令牌** `Theme.accent`（蓝）在本页的停用，而 `Theme`
// 在 SharedUI 包、被 iOS/Mac 多个消费者共用 —— 改它是跨包改动，超出本批写集
// `apps/apple/packages/ChuanqiCutEditor/**`（ADR-0034：写集不相交是硬约束）。
// 故在编辑器域内建立**分域色表**：`Theme.accent` 在首页/其他页面继续有效，
// 只是在编辑页不再被引用。Theme 的整体收敛仍归 UIA-033，届时整表迁移。
//
// ## 单色系的含义
//
// 对标 App 编辑页只有黑 / 白 / 灰：主操作 = **白底黑字**；可用态图标纯白，禁用态是
// 低透明度白（不是另一种灰，避免和背景灰打架）。红色只保留一处语义色：
// **选中态**（时间线白描边、预览红框沿用 TimelinePalette，不动）。
//
// ## 纯度约束（同 TimelinePalette）
//
// 不 import SwiftUI / UIKit 存储色值 —— 复用 `TimelinePalette.RGBA`（同包同语义：
// CoreGraphics 值 + `cgColor` / `uiColor` 转换），不维护第二份 RGB 值类型。

import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

enum EditorChromePalette {

    /// 复用轨道区分域色表的值类型（同包、同语义，避免重复定义 RGBA）。
    typealias RGBA = TimelinePalette.RGBA

    // MARK: - 底色（传输条 / 时间线 / 底栏 三区同色，连成一体）

    /// #0A0A0B。三区统一底色 —— 现状是三档不同底色拼出两条硬边，对标 App 是一条到底。
    static let chromeBackground = RGBA(0.039, 0.039, 0.043, 1.0)
    /// 底栏顶部唯一的分隔手段（0.5pt 发丝线），不用底色差分层。
    static let chromeHairline = RGBA(0.118, 0.118, 0.133, 1.0)

    // MARK: - 前景（图标 / 标签）

    static let chromeGlyph = RGBA(1.0, 1.0, 1.0, 1.0)
    /// 禁用态：低透明度白（与背景灰拉开层级，但仍是同一族）。
    static let chromeGlyphDisabled = RGBA(1.0, 1.0, 1.0, 0.28)
    static let chromeLabel = RGBA(0.812, 0.812, 0.831, 1.0)
    static let chromeLabelDisabled = RGBA(1.0, 1.0, 1.0, 0.28)
    /// 时间码（等宽 12pt）。
    static let chromeTimecode = RGBA(0.541, 0.541, 0.565, 1.0)

    // MARK: - 主操作（白底黑字）

    static let chromePrimaryFill = RGBA(1.0, 1.0, 1.0, 1.0)
    static let chromePrimaryText = RGBA(0.067, 0.067, 0.078, 1.0)
    /// 导出置灰底（EXPORT-001 未就绪，诚实降级：形状先立住，点了没反应）。
    static let chromeDisabledFill = RGBA(0.173, 0.173, 0.188, 1.0)
    static let chromeDisabledText = RGBA(0.431, 0.431, 0.451, 1.0)

    // MARK: - 空态（元素直接落在预览区，不套卡片）

    static let chromeEmptyGlyph = RGBA(0.290, 0.290, 0.314, 1.0)
    static let chromeEmptyText = RGBA(0.541, 0.541, 0.565, 1.0)
}

/// 编辑页外壳尺寸阶梯（对标 App 对齐；[E] 具体数值以真机走查校准为准）。
enum EditorChrome {
    /// 底栏：58 → 84（UIA-043，58 太挤）→ **64**（2026-10-15 传哲：「固定大小就行，
    /// 不要太大」）。64 是定值，不随内容/机型自适应；图标 20 / 标签 10 / 间距 4
    /// —— 元素总高 34，上下各留 15，既不挤也不占屏。
    static let toolbarHeight: CGFloat = 64
    static let toolbarIconPointSize: CGFloat = 20
    static let toolbarLabelFontSize: CGFloat = 10
    /// 图标与标签之间（58pt 时代的 2pt 太挤，84pt 时代的 6pt 在 64 里偏散）。
    static let toolbarIconLabelSpacing: CGFloat = 4
    static let toolbarHorizontalInset: CGFloat = 4

    /// 传输条：撤销/重做（左）· 播放（水平居中）· 时间码（右）。
    static let transportHeight: CGFloat = 44
    static let transportPlaySize: CGFloat = 36
    static let transportHistorySize: CGFloat = 32
    static let transportHorizontalInset: CGFloat = 16
    static let transportHistorySpacing: CGFloat = 10

    /// 时间线（空态保留高度，避免导入瞬间布局跳动）。
    ///
    /// 140 → 220（2026-10-15 传哲：「轨道区变大，至少跟剪映对齐」）。
    /// 220 的账：标尺 24 + 主轨 68 + 副轨 52 ≈ 一屏三条轨（再多由组件纵向滚动），
    /// 与对标 App 竖屏「轨道区约占屏高三分之一」同量级。**[E]**：具体数值来自
    /// 对标 App 截图判读（P128：模型不读图，我没实际看到），以真机走查校准为准。
    static let timelineHeight: CGFloat = 220

    /// 主操作胶囊（空态「打开素材库」）/ 顶栏按钮圆角。
    static let primaryCornerRadius: CGFloat = 6
    static let topBarButtonCornerRadius: CGFloat = 4
}
