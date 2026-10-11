// ChuanqiCutEditor — 底部操作面板（UIA-032 → UIA-040 分级）
//
// RESEARCH-008 范式①⑤：单焦点 + 抽屉，无常驻属性栏 —— 底部整条替换：
//   * primary     —— 一级工具位：撤销/重做 + 媒体/画中画/音频/文字/特效
//                    （音频/文字/特效点击展开二级替换条，不再是死置灰）；
//   * clipSelected —— 选中片段动作条：返回/分割/删除 + 音量/变速占位；
//   * drawer(...) —— 音频/文字/特效/比例替换条；比例 = 真实能力（setCanvas），
//                    其余为入口形状占位（能力未就绪不伪装可用）。
// 模式单一真源 = EditorViewModel.toolbarMode（UI 状态），本视图只渲染。
//
// macOS 不挂本条（撤销/重做仍在 TimelineZone 头部吃 Cmd 快捷键，macOS 惯例化批次再进菜单栏）。

import SwiftUI
import ChuanqiCutEngine
import SharedUI  // 基座：Theme/注入点（ADR-0031）

struct EditorBottomToolbar: View {
    @EnvironmentObject private var viewModel: EditorViewModel

    /// 打开媒体抽屉（开关在 EditorView：预览空态与工具栏共用一个 sheet）。
    let onOpenMedia: () -> Void

    var body: some View {
        Group {
            switch viewModel.toolbarMode {
            case .primary:
                primaryBar
            case .clipSelected:
                clipSelectedBar
            case .drawer(let kind):
                drawerBar(kind)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.toolbarBackground)
    }

    // MARK: 一级（撤销/重做 + 工具位 + 抽屉入口）

    private var primaryBar: some View {
        HStack(spacing: 0) {
            toolbarButton(icon: "arrow.uturn.backward", label: "撤销",
                          enabled: viewModel.canUndo) { viewModel.undo() }
            toolbarButton(icon: "arrow.uturn.forward", label: "重做",
                          enabled: viewModel.canRedo) { viewModel.redo() }

            Spacer(minLength: 0)

            toolbarButton(icon: "film.stack", label: "媒体", enabled: true, action: onOpenMedia)
            // 画中画（UIA-040）：新增一条视频轨 —— 多轨操作的入口。
            toolbarButton(icon: "square.on.square", label: "画中画", enabled: true) {
                viewModel.addOverlayTrack()
            }
            toolbarButton(icon: "music.note", label: "音频", enabled: true) {
                viewModel.openDrawer(.audio)
            }
            toolbarButton(icon: "textformat", label: "文字", enabled: true) {
                viewModel.openDrawer(.text)
            }
            toolbarButton(icon: "sparkles", label: "特效", enabled: true) {
                viewModel.openDrawer(.effects)
            }
            // 比例（UIA-040）：画布抽屉入口（真实能力 setCanvas）。
            toolbarButton(icon: "aspect.ratio", label: "比例", enabled: true) {
                viewModel.openDrawer(.ratio)
            }
        }
    }

    // MARK: 二级 —— 选中片段动作条（范式⑤ 整条替换）

    private var clipSelectedBar: some View {
        HStack(spacing: 0) {
            toolbarButton(icon: "chevron.down", label: "返回", enabled: true) {
                viewModel.closePanel()
            }
            toolbarButton(icon: "scissors", label: "分割",
                          enabled: viewModel.canSplitSelected) {
                viewModel.splitSelectedAtPlayhead()
            }
            toolbarButton(icon: "trash", label: "删除",
                          enabled: viewModel.selectedClipId != nil) {
                viewModel.deleteSelectedClip()
            }

            Spacer(minLength: 0)

            // 占位：MODEL-003 属性系统落地后接真。
            toolbarButton(icon: "speaker.wave.2", label: "音量", enabled: false, action: {})
            toolbarButton(icon: "speedometer", label: "变速", enabled: false, action: {})
        }
    }

    // MARK: 二级 —— 抽屉替换条

    @ViewBuilder
    private func drawerBar(_ kind: EditorDrawerKind) -> some View {
        HStack(spacing: 0) {
            toolbarButton(icon: "chevron.down", label: "返回", enabled: true) {
                viewModel.closePanel()
            }
            Spacer(minLength: 0)
            switch kind {
            case .ratio:
                // 比例 = 真实能力（setCanvas；宽高只是比例语义，渲染目标跟随）。
                toolbarButton(icon: "rectangle.portrait", label: "9:16", enabled: true) {
                    viewModel.setCanvas(width: 1080, height: 1920)
                }
                toolbarButton(icon: "rectangle.landscape", label: "16:9", enabled: true) {
                    viewModel.setCanvas(width: 1920, height: 1080)
                }
                toolbarButton(icon: "square", label: "1:1", enabled: true) {
                    viewModel.setCanvas(width: 1080, height: 1080)
                }
                toolbarButton(icon: "rectangle", label: "4:3", enabled: true) {
                    viewModel.setCanvas(width: 1440, height: 1080)
                }
                toolbarButton(icon: "rectangle", label: "3:4", enabled: true) {
                    viewModel.setCanvas(width: 1080, height: 1440)
                }
            case .audio:
                toolbarButton(icon: "music.quarternote.3", label: "音乐", enabled: false, action: {})
                toolbarButton(icon: "waveform", label: "音效", enabled: false, action: {})
                toolbarButton(icon: "mic", label: "录音", enabled: false, action: {})
                toolbarButton(icon: "arrow.down.doc", label: "提取", enabled: false, action: {})
            case .text:
                toolbarButton(icon: "plus.rectangle.on.rectangle", label: "新建文字", enabled: false, action: {})
                toolbarButton(icon: "captions.bubble", label: "识别字幕", enabled: false, action: {})
                toolbarButton(icon: "character.book.closed", label: "花字", enabled: false, action: {})
            case .effects:
                toolbarButton(icon: "wand.and.stars", label: "画面特效", enabled: false, action: {})
                toolbarButton(icon: "person.crop.rectangle", label: "人物特效", enabled: false, action: {})
                toolbarButton(icon: "camera.filters", label: "滤镜", enabled: false, action: {})
            }
        }
    }

    /// 图标 + 文字竖排工具位（行业惯例的单手拇指目标）。
    private func toolbarButton(icon: String, label: String, enabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            VStack(spacing: Theme.Space.xs) {
                Image(systemName: icon)
                    .font(.body)
                    .frame(height: 22)
                Text(label)
                    .font(.caption2)
            }
            .foregroundStyle(enabled ? Theme.primaryText : Theme.tertiaryText)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(enabled ? label : "\(label)（未就绪）")
    }
}
