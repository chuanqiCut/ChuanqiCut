// SharedUI — 自研相册浏览器主屏（UIA-013，Spec docs/specs/UIA-013-自研相册浏览器.md）
//
// 交互（v1.1，对齐剪映素材面板的连续导入流）：
//   * **默认单击即插入**：点 cell → loading 覆盖 → 素材进时间线 → toast
//     反馈，面板保持打开（半屏抽屉可拖拽收起），可连续点选 —— 选择与插入
//     同步完成，无需"完成"确认。
//   * **「多选」显式模式**：右上角切换；序号徽标 + 底部托盘 + 批量"添加"。
//     长按 cell 直接进入多选并选中（相册 App 经典手势）。
// 结构：顶栏（取消 / 相簿切换菜单 / 多选切换与计数）→ 受限横幅 → 网格 →
// 底部托盘（多选模式）。
// 交付链路：VM 逐条落 tmp（iCloud 在此联网拉取）→ **async** onDeliver 交付
// 文件 URL 列表 → PropertyPanelZone 的 runBatch 汇入 importMedia（面板保持
// 打开，VM await 到导入完成才结束 loading —— 反馈闭环）。
//
// 已知留白（Spec §7）：受限模式"管理可选照片"系统面板只有 UIKit 入口；
// 选择器内点击预览播放器为后续增量。

import SwiftUI

// MARK: - 主屏

struct AlbumPickerScreen: View {

    @StateObject private var model: MediaPickerViewModel
    @StateObject private var permission = AlbumPermissionModel()
    @Environment(\.dismiss) private var dismiss

    /// 交付成功的文件 URL（顺序 = 选取序号顺序）。async：父层在此完成导入
    /// （runBatch），VM await 到返回才解除 loading。**面板不在此关闭** ——
    /// 剪映式连续导入流，收起靠拖拽指示器 / 取消按钮。
    private let onDeliver: ([URL]) async -> Void

    init(onDeliver: @escaping ([URL]) async -> Void) {
        self.onDeliver = onDeliver
        _model = StateObject(wrappedValue: MediaPickerViewModel(
            fetcher: PhotoKitAlbumStore(),
            onConfirm: { urls in await onDeliver(urls) }))
    }

    // 提示浮层（满选 / 时长超限 / 部分失败）
    @State private var toastText: String?
    @State private var toastDismissTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if permission.access == .limited {
                LimitedLibraryBanner()
            }
            Divider().overlay(Theme.divider)
            content
            if model.isMultiSelectMode && !model.selection.isEmpty {
                bottomTray.transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Theme.editorBackground)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.selection)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.isMultiSelectMode)
        .animation(.easeOut(duration: 0.18), value: permission.access)
        .pickerSheetFrame()
        .mediaPickerPanelPresentation()
        .overlay(alignment: .bottom) { toast }
        .task {
            await permission.requestIfNeeded()
            if permission.shouldShowLibrary, model.currentAlbum == nil {
                model.loadAlbums()
            }
        }
        .onChange(of: permission.access) { access in
            // 授权结果回到主线程状态后装载相簿（首次授权 / 去设置返回）
            if access == .authorized || access == .limited, model.albums.isEmpty {
                model.loadAlbums()
            }
        }
    }

    // MARK: 顶栏

    private var topBar: some View {
        HStack(spacing: 12) {
            Button("取消") { dismiss() }
                .foregroundStyle(Theme.secondaryText)

            Spacer()

            albumMenu

            Spacer()

            // 右侧：多选切换 + 计数（剪映范式：默认单击即插入，多选显式开启）
            if model.isMultiSelectMode {
                Text("\(model.selection.count)/\(model.selection.maxCount)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(model.selection.isFull ? Color.orange : Theme.secondaryText)
            }
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    model.setMultiSelectMode(!model.isMultiSelectMode)
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: model.isMultiSelectMode
                          ? "checkmark.circle.fill" : "checkmark.circle")
                    Text("多选")
                }
                .font(.callout.weight(.medium))
                .foregroundStyle(model.isMultiSelectMode ? PickerTheme.accent : Theme.secondaryText)
            }
            .disabled(model.isPreparingFiles)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// 相簿切换（ZL/HX 顶栏居中切换范式）：名称 + 数量，原生菜单保证可访问性。
    private var albumMenu: some View {
        Menu {
            ForEach(model.albums) { album in
                Button {
                    model.select(album: album)
                } label: {
                    if album == model.currentAlbum {
                        Label("\(album.title)（\(album.assetCount)）", systemImage: "checkmark")
                    } else {
                        Text("\(album.title)（\(album.assetCount)）")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.currentAlbum?.title ?? "相簿")
                    .font(.headline)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .disabled(model.albums.isEmpty)
    }

    // MARK: 内容区（权限三态 / 加载 / 空态 / 网格）

    @ViewBuilder
    private var content: some View {
        switch permission.access {
        case .notDetermined:
            permissionPending
        case .denied:
            PermissionGuideView(onOpenSettings: PickerFeedback.openSystemSettings)
        case .authorized, .limited:
            libraryContent
        }
    }

    private var permissionPending: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundStyle(Theme.tertiaryText)
            Text("正在请求相册访问权限…")
                .font(.callout)
                .foregroundStyle(Theme.secondaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var libraryContent: some View {
        if !model.hasLoaded {
            ProgressView()
                .tint(Theme.tertiaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.albums.isEmpty {
            emptyLibrary("相册中没有视频")
        } else if model.isLibraryEmpty {
            emptyLibrary("该相簿中没有视频")
        } else {
            grid
        }
    }

    private func emptyLibrary(_ message: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "film")
                .font(.system(size: 40))
                .foregroundStyle(Theme.tertiaryText)
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.secondaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: model.configuration.minColumnWidth), spacing: 1)],
                spacing: 1) {
                ForEach(model.assets) { descriptor in
                    MediaGridCell(
                        assetDescriptor: descriptor,
                        fetcher: model.fetcher,
                        // 徽标/满选置灰只在多选模式出现；单击模式的反馈是 loading 覆盖层
                        orderNumber: model.isMultiSelectMode
                            ? model.selection.orderNumber(of: descriptor.id) : nil,
                        dimmedByFull: model.isMultiSelectMode && model.selection.isFull,
                        rejectionReason: DurationFilter.rejectionReason(
                            durationSeconds: descriptor.durationSeconds,
                            allowed: model.configuration.allowedDuration),
                        isLoading: model.insertingIDs.contains(descriptor.id),
                        onTap: { handleTap(descriptor) },
                        // 长按：单击模式直接进入多选并选中（相册 App 经典手势）
                        onLongPress: model.isMultiSelectMode ? nil : {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                model.setMultiSelectMode(true)
                            }
                            _ = model.toggleSelect(descriptor)
                            PickerFeedback.selectionChanged()
                        })
                }
            }
            .padding(.bottom, 8)
        }
    }

    // MARK: 底部已选托盘

    private var bottomTray: some View {
        HStack(spacing: 12) {
            Button {
                model.clearSelection()
            } label: {
                Text("清空")
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryText)
            }
            .disabled(model.isPreparingFiles)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(model.selectedInOrder.enumerated()), id: \.element.id) { index, asset in
                        TrayThumbCell(asset: asset, fetcher: model.fetcher, order: index + 1) {
                            _ = model.toggleSelect(asset)   // 点托盘缩略图 = 取消选取
                        }
                    }
                }
                .padding(.horizontal, 2)
            }

            confirmButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(PickerTheme.trayBackground)
    }

    private var confirmButton: some View {
        Button {
            Task { await model.confirm() }
        } label: {
            Text(model.isPreparingFiles ? (model.preparingText ?? "准备中…")
                 : "添加（\(model.selection.count)）")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(model.selection.isEmpty && !model.isPreparingFiles
                                   ? PickerTheme.accent.opacity(0.35)
                                   : PickerTheme.accent))
        }
        .disabled(model.selection.isEmpty || model.isPreparingFiles)
        .accessibilityLabel("添加 \(model.selection.count) 个所选视频到时间线")
    }

    // MARK: 交互

    private func handleTap(_ descriptor: AssetDescriptor) {
        guard !model.isPreparingFiles else { return }
        if model.isMultiSelectMode {
            let feedback = model.toggleSelect(descriptor)
            PickerFeedback.selectionChanged()
            switch feedback {
            case .selected, .deselected:
                break
            case .rejectedFull:
                showToast("最多选择 \(model.selection.maxCount) 个视频")
            case .rejectedDuration(let reason):
                showToast(reason)
            }
        } else {
            // 单击即插入（剪映式）：loading 覆盖在 cell 上，await 导入完成后 toast
            Task {
                let outcome = await model.insertSingle(descriptor)
                switch outcome {
                case .delivered:
                    showToast("已添加到时间线")
                case .rejectedDuration(let reason):
                    showToast(reason)
                case .failed(let detail):
                    showToast("添加失败：\(detail)")
                case .busy:
                    showToast("正在处理上一条…")
                }
            }
        }
    }

    // MARK: 提示浮层

    private var toast: some View {
        Group {
            if let toastText {
                Text(toastText)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.8)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                    .padding(.bottom, 64)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: toastText)
    }

    private func showToast(_ text: String) {
        toastDismissTask?.cancel()
        withAnimation { toastText = text }
        toastDismissTask = Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { toastText = nil }
        }
    }
}

// MARK: - 底部托盘缩略图（带序号，点击取消选取）

private struct TrayThumbCell: View {

    let asset: AssetDescriptor
    let fetcher: AlbumFetching
    let order: Int
    let onTap: () -> Void

    @StateObject private var loader: ThumbnailLoader

    init(asset: AssetDescriptor, fetcher: AlbumFetching, order: Int, onTap: @escaping () -> Void) {
        self.asset = asset
        self.fetcher = fetcher
        self.order = order
        self.onTap = onTap
        _loader = StateObject(wrappedValue: ThumbnailLoader(assetID: asset.id, fetcher: fetcher))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = loader.image {
                    PlatformImageView(image: image).scaledToFill()
                } else {
                    Theme.panelBackground
                        .overlay(Image(systemName: "film")
                            .font(.caption)
                            .foregroundStyle(Theme.tertiaryText))
                }
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text("\(order)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(PickerTheme.accent))
                .overlay(Circle().strokeBorder(.white, lineWidth: 1))
                .offset(x: 5, y: -5)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onAppear { loader.load() }
        .accessibilityLabel("已选第 \(order) 个视频，点按取消")
    }
}

// MARK: - 受限模式横幅

private struct LimitedLibraryBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.footnote)
            Text("当前仅可访问部分照片；如需完整图库，请在系统设置中调整授权")
                .font(.caption)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}

// MARK: - 权限拒绝引导

private struct PermissionGuideView: View {
    // 与 PickerFeedback.openSystemSettings 同为 @MainActor：Button action 在
    // SwiftUI 里本就跑在主线程，标出来让编译器把住这层。
    @MainActor var onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 44))
                .foregroundStyle(Theme.tertiaryText)
            Text("无法访问相册")
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
            Text("导入相册视频需要照片权限。\n请在系统设置 → 隐私与安全性 → 照片中允许访问。")
                .font(.callout)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            Button {
                onOpenSettings()
            } label: {
                Text("去设置")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(PickerTheme.accent))
            }
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }
}

// MARK: - 系统交互（震动 / 设置跳转；平台分支为 UI 管道，非能力推断）

enum PickerFeedback {

    // UIImpactFeedbackGenerator / UIApplication.shared 在 Swift 6 里是
    // @MainActor 隔离的，静态方法不标就只能在 nonisolated 上下文"偷渡"——
    // 这里显式标 @MainActor，让调用点由编译器校验（Swift 6 严格并发下
    // 从后台调 UIKit 是真会出问题的，不是可忽略的警告）。
    @MainActor static func selectionChanged() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    @MainActor static func openSystemSettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #elseif canImport(AppKit)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}

// MARK: - sheet 尺寸与呈现形态（macOS 固定窗口；iOS 半屏抽屉可拉满 —— 剪映式素材面板）

private extension View {
    @ViewBuilder
    func pickerSheetFrame() -> some View {
        #if canImport(AppKit)
        frame(minWidth: 720, idealWidth: 880, minHeight: 560, idealHeight: 640)
        #else
        self
        #endif
    }

    /// iOS：medium/large 两档 detents + 拖拽指示器（iOS 16 基线内；
    /// presentationBackgroundInteraction 需 16.4+，超出基线不用）。
    /// macOS：窗口形态，无需 detents。
    @ViewBuilder
    func mediaPickerPanelPresentation() -> some View {
        #if canImport(UIKit)
        presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        #else
        self
        #endif
    }
}
