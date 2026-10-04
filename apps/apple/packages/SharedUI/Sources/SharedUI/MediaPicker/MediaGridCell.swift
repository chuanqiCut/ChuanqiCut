// SharedUI — 自研相册浏览器：网格 cell（UIA-013）
//
// 交互与视觉范式对齐 ZLPhotoBrowser / HXPhotoPicker：
//   * 缩略图满铺方格、1pt 缝隙（相册 App 观感）
//   * 右上角序号徽标：空心圆 → 主题色实心圆 + 白色序号（选取顺序可视化）
//   * 右下角时长角标（黑胶囊 + 视频图标），左下角 iCloud 云徽标
//   * 满选时未选 cell 整体压暗（ZL 满选置灰），时长超限 cell 灰化 + 原因文案
// 缩略图经 AlbumFetching 请求（生产 = PHCachingImageManager，opportunistic
// 先低清后高清），云端素材不在此联网 —— 显示占位 + 云徽标。

import SwiftUI

// MARK: - 选择器配色（暗色，与编辑器 Theme 同族；不进 Theme.swift —— 写集隔离）

enum PickerTheme {
    /// 选取强调色：时间线片段蓝的亮化版（选中徽标 / 完成按钮）。
    static let accent = Color(red: 0.32, green: 0.55, blue: 0.86)
    static let trayBackground = Color(red: 0.10, green: 0.10, blue: 0.12)
}

// MARK: - 缩略图加载器（cell 级 ObservableObject）

@MainActor
final class ThumbnailLoader: ObservableObject {

    @Published var image: PlatformImage?
    @Published var isCloudOnly = false

    private let assetID: String
    private let fetcher: AlbumFetching

    init(assetID: String, fetcher: AlbumFetching) {
        self.assetID = assetID
        self.fetcher = fetcher
    }

    func load() {
        guard image == nil, !isCloudOnly else { return }
        fetcher.requestThumbnail(assetID: assetID, targetSize: PhotoKitAlbumStore.thumbnailTargetSize) {
            [weak self] image, isCloudOnly in
            self?.image = image
            self?.isCloudOnly = isCloudOnly && image == nil
        }
    }

    func cancel() {
        fetcher.cancelThumbnail(assetID: assetID)
    }
}

// MARK: - 跨平台图像视图

struct PlatformImageView: View {
    let image: PlatformImage

    var body: some View {
        #if canImport(UIKit)
        Image(uiImage: image)
            .resizable()
        #elseif canImport(AppKit)
        Image(nsImage: image)
            .resizable()
        #endif
    }
}

// MARK: - 网格 cell

struct MediaGridCell: View {

    let descriptor: AssetDescriptor
    /// 徽标序号；nil = 未选中（或非多选模式 —— 徽标只在多选模式出现）。
    let orderNumber: Int?
    /// 满选导致的置灰（仅多选模式会出现）。
    let dimmedByFull: Bool
    /// 时长过滤的不可选原因；非 nil = 灰化 + 文案 + 不可点。
    let rejectionReason: String?
    /// 单击插入进行中（剪映式：loading 覆盖"落 tmp + 进时间线"全程）。
    let isLoading: Bool
    let onTap: () -> Void
    /// 长按进多选并选中本条（仅单击模式提供；nil = 无长按行为）。
    let onLongPress: (() -> Void)?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                thumbnail
                // 满选置灰：整体压暗、不响应（ZL 满选置灰范式）
                if dimmedByFull && orderNumber == nil {
                    Theme.editorBackground.opacity(0.55)
                        .allowsHitTesting(false)
                }
                if orderNumber != nil {
                    // 已选轻压暗：让白色序号徽标更醒目
                    Theme.editorBackground.opacity(0.12)
                        .allowsHitTesting(false)
                }
                badge
            }
            .overlay(alignment: .bottomTrailing) { durationBadge }
            .overlay(alignment: .bottomLeading) { cloudBadge }
            .overlay(alignment: .center) { rejectionOverlay }
            .overlay { insertingOverlay }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .onLongPressGesture(minimumDuration: 0.45) { onLongPress?() }
            .onAppear { if rejectionReason == nil { loader.load() } }
            .onDisappear { loader.cancel() }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(orderNumber != nil ? .isSelected : [])
    }

    @StateObject private var loader: ThumbnailLoader

    init(assetDescriptor: AssetDescriptor,
         fetcher: AlbumFetching,
         orderNumber: Int?,
         dimmedByFull: Bool,
         rejectionReason: String?,
         isLoading: Bool = false,
         onTap: @escaping () -> Void,
         onLongPress: (() -> Void)? = nil) {
        self.descriptor = assetDescriptor
        self.orderNumber = orderNumber
        self.dimmedByFull = dimmedByFull
        self.rejectionReason = rejectionReason
        self.isLoading = isLoading
        self.onTap = onTap
        self.onLongPress = onLongPress
        _loader = StateObject(wrappedValue: ThumbnailLoader(
            assetID: assetDescriptor.id, fetcher: fetcher))
    }

    // ---- 单击插入的 loading 覆盖层 ----

    @ViewBuilder
    private var insertingOverlay: some View {
        if isLoading {
            ZStack {
                Theme.editorBackground.opacity(0.5)
                ProgressView()
                    .tint(.white)
                    .scaleEffect(0.85)
            }
            .allowsHitTesting(false)
        }
    }

    // ---- 缩略图 / 占位 ----

    @ViewBuilder
    private var thumbnail: some View {
        if let image = loader.image {
            PlatformImageView(image: image)
                .scaledToFill()
        } else {
            ZStack {
                Theme.panelBackground
                if loader.isCloudOnly {
                    // 仅云端：确认导出时才联网拉取（PhotoKitAlbumStore 注释）
                    Image(systemName: "icloud")
                        .font(.title3)
                        .foregroundStyle(Theme.tertiaryText)
                } else {
                    ProgressView().tint(Theme.tertiaryText)
                }
            }
        }
    }

    // ---- 右上角序号徽标 ----

    private var badge: some View {
        ZStack {
            if let orderNumber {
                Circle()
                    .fill(PickerTheme.accent)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                    .transition(.scale.combined(with: .opacity))
                Text("\(orderNumber)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            } else {
                Circle()
                    .fill(Theme.editorBackground.opacity(0.35))
                    .overlay(Circle().strokeBorder(.white.opacity(0.75), lineWidth: 1.5))
            }
        }
        .frame(width: 22, height: 22)
        .padding(5)
    }

    // ---- 右下角时长角标 ----

    private var durationBadge: some View {
        Text(Self.durationText(descriptor.durationSeconds))
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(.black.opacity(0.55)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .padding(4)
    }

    // ---- 左下角 iCloud 徽标 ----

    @ViewBuilder
    private var cloudBadge: some View {
        if loader.isCloudOnly {
            HStack(spacing: 2) {
                Image(systemName: "icloud.fill")
                Text("云端")
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(.black.opacity(0.55)))
            .padding(4)
        }
    }

    // ---- 时长超限置灰 ----

    @ViewBuilder
    private var rejectionOverlay: some View {
        if let rejectionReason {
            ZStack {
                Theme.editorBackground.opacity(0.68)
                VStack(spacing: 3) {
                    Image(systemName: "video.slash")
                        .font(.footnote)
                    Text(rejectionReason)
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(Theme.tertiaryText)
                .padding(.horizontal, 4)
            }
        }
    }

    private var accessibilityText: String {
        var text = "视频，时长 \(Self.durationText(descriptor.durationSeconds))"
        if let orderNumber { text += "，已选第 \(orderNumber) 个" }
        if let rejectionReason { text += "，\(rejectionReason)" }
        return text
    }

    // ---- 工具 ----

    /// m:ss / h:mm:ss 角标文本。
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
