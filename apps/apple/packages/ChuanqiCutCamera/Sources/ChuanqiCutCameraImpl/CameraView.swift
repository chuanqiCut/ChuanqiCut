// CameraView — 相机页（CAM-004，ADR-0014：iOS 专属，不进 MacApp）
//
// 结构：预览铺满 + 顶部翻转钮 + 底部（滤镜条 + 录制钮）+ 录制产物面板。
// 权限拒绝态明示引导（SPEC-CAM-001 v1.1 A6：不闪退、给出路）。

import AVFoundation
import SharedUI  // EditorEntryInjector（ADR-0031：编辑器域经基座注入点进入，横向零依赖）
import SwiftUI

public struct CameraView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: CameraViewModel
    @State private var showEditor = false
    @State private var showBeautyPanel = false
    @State private var showSettings = false
    /// 捏合变焦基值（onEnded 归一，连续捏合可叠加）。
    @State private var pinchBaseZoom: CGFloat = 1.0

    public init() {
        // 先建值后包装（pitfalls P8 同款）：构造不再抛错，Metal 不可用由
        // renderer == nil 的降级文案兜底。
        _model = StateObject(wrappedValue: CameraViewModel())
    }

    public var body: some View {
        Group {
            if model.renderer == nil {
                fallbackView(text: "Metal 设备不可用，相机无法运行")
            } else {
                switch model.phase {
                case .preparing:
                    ProgressView("正在启动相机…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black)
                case .unauthorized:
                    unauthorizedView
                case .running:
                    runningView
                }
            }
        }
        .onAppear {
            // 先注入当前方向再启动会话：configure 在 sessionQueue 取用的就是它
            // （避免「先竖屏启动、后补转」的首帧方向抖动）。
            model.updateInterfaceOrientation(CameraViewModel.currentInterfaceOrientation())
            model.prepare()
        }
        // 界面方向跟踪（CAM-016）：触发源 = UIDevice 设备方向变化；取值侧读
        // active scene 的 interfaceOrientation（尊重 Info.plist/页面锁向的现实），
        // 并在 ViewModel 内分段采样避开「通知早于 scene 提交转场」竞态。
        .onReceive(NotificationCenter.default.publisher(
            for: UIDevice.orientationDidChangeNotification)) { _ in
            model.refreshInterfaceOrientation()
        }
        // iOS 16 兼容的单参 onChange（两参重载 iOS 17 起，P48 抓出；项目部署目标 16.0）
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background || newPhase == .inactive {
                model.handleSceneInactive()
            } else if newPhase == .active {
                model.resumeIfNeeded()
            }
        }
        .alert(item: Binding(
            get: { model.errorMessage.map(CameraAlert.init(message:)) },
            set: { _ in model.clearError() }
        )) { alert in
            Alert(title: Text("提示"), message: Text(alert.message))
        }
        .navigationDestination(isPresented: $showEditor) {
            // ADR-0031：编辑器域经基座注入点进入（EditorScreen 由壳层装配）；
            // 未注入（单测环境）空占位，录制产物丢弃语义保持不变。
            if let editor = EditorEntryInjector.makeEditor?(model.recordedURL) {
                editor
                    .onDisappear { model.discardRecording() }
                    // 录制产物进编辑器且不保留本地临时文件语义：导入后放弃临时文件。
                    // （importMedia 走原路径引用，见 UIA-009 的 D3 决策。）
            } else {
                Color.clear.onDisappear { model.discardRecording() }
            }
        }
    }

    // MARK: 运行态

    private var runningView: some View {
        ZStack {
            if let renderer = model.renderer {
                CameraVideoView(renderer: renderer)
                    .ignoresSafeArea()
                    // 捏合变焦（2026-10-07 用户反馈轮）：请求值粗限 1...16，
                    // 设备实际范围由 manager 按 activeFormat 夹取。
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                model.zoomFactor = min(max(pinchBaseZoom * value, 1), 16)
                            }
                            .onEnded { _ in
                                pinchBaseZoom = model.zoomFactor
                            }
                    )
            }
            VStack {
                topBar
                Spacer()
                modePicker
                stickerStrip
                filterStrip
                shutterBar
            }
            if let url = model.recordedURL {
                recordedPanel(url: url)
            }
        }
        .sheet(isPresented: $showBeautyPanel) {
            beautyPanel
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showSettings) {
            settingsPanel
                .presentationDetents([.medium])
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                showBeautyPanel = true
            } label: {
                let allOff = model.beauty.isOff && model.reshape.isOff && model.bodyReshape.isOff
                Image(systemName: allOff ? "face.dashed" : "face.smiling")
                    .font(.title2)
                    .foregroundStyle(allOff ? .white : .yellow)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .disabled(model.isRecording)
            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .disabled(model.isRecording)
            .padding(.leading, 8)
            dualCamToggle
            Spacer()
            recordingTimer
            Spacer()
            if model.dualCamEnabled {
                // 双摄：互换主画面/PiP（SPEC A8：PiP 可与主画面互换；录制中锁定）
                Button {
                    model.swapPiP()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .disabled(model.isRecording)
                .padding(.trailing, 20)
            } else {
                Button {
                    guard !model.isRecording else { return }  // 录制中锁切换
                    model.switchPosition()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .disabled(model.isRecording || model.isCapturing)
                .padding(.trailing, 20)
            }
        }
        .padding(.top, 8)
    }

    /// 双摄开关（CAM-021；SPEC A8：不支持机型置灰，设置面板明示文案）。
    /// 与翻转按钮**相互独立**——双摄开关不复用翻转按钮（SPEC v1.2 拍板）。
    private var dualCamToggle: some View {
        Button {
            model.setDualCamEnabled(!model.dualCamEnabled)
        } label: {
            Image(systemName: model.dualCamEnabled ? "camera.on.rectangle.fill" : "camera.on.rectangle")
                .font(.title2)
                .foregroundStyle(model.isDualCamSupported ? .white : .white.opacity(0.35))
                .padding(12)
                .background(.ultraThinMaterial, in: Circle())
        }
        .disabled(model.isRecording || !model.isDualCamSupported)
    }

    /// 录制计时（红点 + mm:ss，TimelineView 每 0.5s 走针；起点由 ViewModel 记录）。
    @ViewBuilder
    private var recordingTimer: some View {
        if model.isRecording, let startedAt = model.recordingStartedAt {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                    Text(String(format: "%02d:%02d", elapsed / 60, elapsed % 60))
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    /// 拍照 / 视频模式切换（录制与拍照过程中锁定）。
    private var modePicker: some View {
        Picker("模式", selection: $model.mode) {
            Image(systemName: "camera").tag(CameraViewModel.CaptureMode.photo)
            Image(systemName: "video").tag(CameraViewModel.CaptureMode.video)
        }
        .pickerStyle(.segmented)
        .frame(width: 140)
        .disabled(model.isRecording || model.isCapturing)
        .tint(.white)
    }

    /// 贴纸选择条（CAM-014，与滤镜条同款式）。目录为空（无清单/无资产）时
    /// 整体隐藏——不出现假入口。录制中锁定（WYSIWYG 锁定语义）。
    @ViewBuilder
    private var stickerStrip: some View {
        if !model.stickerCatalog.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Button {
                        model.selectedStickerID = nil
                    } label: {
                        Text("无贴纸")
                            .font(.footnote.weight(model.selectedStickerID == nil ? .semibold : .regular))
                            .foregroundStyle(model.selectedStickerID == nil ? .black : .white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                model.selectedStickerID == nil ? Color.white : Color.white.opacity(0.25),
                                in: Capsule()
                            )
                    }
                    ForEach(model.stickerCatalog) { asset in
                        Button {
                            model.selectedStickerID = asset.id
                        } label: {
                            Text(asset.displayName)
                                .font(.footnote.weight(model.selectedStickerID == asset.id ? .semibold : .regular))
                                .foregroundStyle(model.selectedStickerID == asset.id ? .black : .white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    model.selectedStickerID == asset.id ? Color.white : Color.white.opacity(0.25),
                                    in: Capsule()
                                )
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 4)
            .disabled(model.isRecording)
        }
    }

    private var filterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(CameraFilterPreset.allCases) { preset in
                    Button {
                        model.filter = preset
                    } label: {
                        Text(preset.displayName)
                            .font(.footnote.weight(model.filter == preset ? .semibold : .regular))
                            .foregroundStyle(model.filter == preset ? .black : .white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                model.filter == preset ? Color.white : Color.white.opacity(0.25),
                                in: Capsule()
                            )
                    }
                    .disabled(model.isRecording)  // 录制中锁滤镜（WYSIWYG 锁定语义）
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 4)
    }

    /// 双态快门：照片模式 = 白圈（拍照）；视频模式 = 录制钮（红点/方点动画）。
    private var shutterBar: some View {
        HStack {
            Spacer()
            Group {
                if model.mode == .photo {
                    Button {
                        model.capturePhoto()
                    } label: {
                        ZStack {
                            Circle()
                                .strokeBorder(.white, lineWidth: 4)
                                .frame(width: 72, height: 72)
                            Circle()
                                .fill(.white)
                                .frame(width: 58, height: 58)
                                .opacity(model.isCapturing ? 0.35 : 1)
                        }
                    }
                    .disabled(model.isCapturing)
                } else {
                    Button {
                        if model.isRecording {
                            model.stopRecording()
                        } else {
                            model.startRecording()
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .strokeBorder(.white, lineWidth: 4)
                                .frame(width: 72, height: 72)
                            Circle()
                                .fill(model.isRecording ? Color.red : Color.white)
                                .frame(width: model.isRecording ? 30 : 58,
                                       height: model.isRecording ? 30 : 58)
                                .animation(.easeInOut(duration: 0.2), value: model.isRecording)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(.bottom, 28)
    }

    // MARK: 美颜面板（磨皮/美白/美型即时生效；美型 = CAM-013 三滑杆）

    private var beautyPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("美颜").font(.headline)
            HStack {
                Text("磨皮").frame(width: 44, alignment: .leading)
                Slider(value: Binding(
                    get: { model.beauty.smoothing },
                    set: { model.beauty.smoothing = $0 }
                ), in: 0...1)
                Text("\(Int(model.beauty.smoothing * 100))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 32)
            }
            HStack {
                Text("美白").frame(width: 44, alignment: .leading)
                Slider(value: Binding(
                    get: { model.beauty.brightening },
                    set: { model.beauty.brightening = $0 }
                ), in: 0...1)
                Text("\(Int(model.beauty.brightening * 100))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 32)
            }
            HStack {
                Text("瘦脸").frame(width: 44, alignment: .leading)
                Slider(value: Binding(
                    get: { model.reshape.slimFace },
                    set: { model.reshape.slimFace = $0 }
                ), in: 0...1)
                Text("\(Int(model.reshape.slimFace * 100))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 32)
            }
            HStack {
                Text("大眼").frame(width: 44, alignment: .leading)
                Slider(value: Binding(
                    get: { model.reshape.enlargeEye },
                    set: { model.reshape.enlargeEye = $0 }
                ), in: 0...1)
                Text("\(Int(model.reshape.enlargeEye * 100))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 32)
            }
            HStack {
                Text("下巴").frame(width: 44, alignment: .leading)
                Slider(value: Binding(
                    get: { model.reshape.chinShrink },
                    set: { model.reshape.chinShrink = $0 }
                ), in: 0...1)
                Text("\(Int(model.reshape.chinShrink * 100))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 32)
            }
            HStack {
                Text("瘦腰").frame(width: 44, alignment: .leading)
                Slider(value: Binding(
                    get: { model.bodyReshape.slimWaist },
                    set: { model.bodyReshape.slimWaist = $0 }
                ), in: 0...1)
                Text("\(Int(model.bodyReshape.slimWaist * 100))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 32)
            }
            HStack {
                Text("长腿").frame(width: 44, alignment: .leading)
                Slider(value: Binding(
                    get: { model.bodyReshape.lengthenLegs },
                    set: { model.bodyReshape.lengthenLegs = $0 }
                ), in: 0...1)
                Text("\(Int(model.bodyReshape.lengthenLegs * 100))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 32)
            }
            HStack {
                Button("重置") {
                    model.beauty = .off
                    model.reshape = .off
                    model.bodyReshape = .off
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("完成") {
                    showBeautyPanel = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .presentationDragIndicator(.visible)
    }

    // MARK: 拍摄设置面板（2026-10-07 用户反馈轮：档位/帧率/高清拍照/曝光/对焦）
    //
    // 录制中整个入口禁用：分辨率/帧率变更会重配会话，破坏 writer 的缓冲尺寸契约；
    // 曝光/对焦虽可安全实时调，统一锁定保持「录制中锁设置」的简单语义。

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("拍摄设置").font(.headline)
            HStack {
                Text("分辨率").frame(width: 64, alignment: .leading)
                Picker("分辨率", selection: Binding(
                    get: { model.captureQuality },
                    set: { model.setCaptureQuality($0) }
                )) {
                    ForEach(CameraManager.CaptureQuality.allCases, id: \.self) { quality in
                        Text(qualityLabel(quality)).tag(quality)
                    }
                }
                .pickerStyle(.segmented)
            }
            HStack {
                Text("帧率").frame(width: 64, alignment: .leading)
                Picker("帧率", selection: Binding(
                    get: { model.frameRate },
                    set: { model.setFrameRate($0) }
                )) {
                    Text("30").tag(30)
                    Text("60").tag(60)
                }
                .pickerStyle(.segmented)
            }
            Toggle("高清拍照（全分辨率）", isOn: $model.highResPhoto)
            Toggle("MetalFX 预览增强（实验）", isOn: $model.fxUpscaleEnabled)
            if !model.isDualCamSupported {
                // SPEC-CAM-001 A8：不支持机型明示（顶栏开关已置灰）
                Text("本机不支持双摄（需 A12 及以上机型）")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("曝光").frame(width: 64, alignment: .leading)
                Slider(value: $model.exposureBias, in: -2...2)
                Text(String(format: "%+.1f", model.exposureBias))
                    .font(.caption.monospacedDigit())
                    .frame(width: 44)
            }
            HStack {
                Text("对焦").frame(width: 64, alignment: .leading)
                Slider(value: Binding(
                    get: { model.focusLensPosition ?? 0.5 },
                    set: { model.focusLensPosition = $0 }
                ), in: 0...1)
                Text(model.focusLensPosition.map { String(format: "%.2f", $0) } ?? "自动")
                    .font(.caption.monospacedDigit())
                    .frame(width: 44)
            }
            HStack {
                Button("重置对焦/曝光") {
                    model.resetFocusAndExposure()
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("完成") {
                    showSettings = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .presentationDragIndicator(.visible)
    }

    private func qualityLabel(_ quality: CameraManager.CaptureQuality) -> String {
        switch quality {
        case .hd720: return "720p"
        case .hd1080: return "1080p"
        case .uhd4K: return "4K"
        }
    }

    // MARK: 录制产物面板

    private func recordedPanel(url: URL) -> some View {
        VStack(spacing: 16) {
            Text("录制完成").font(.headline).foregroundStyle(.white)
            HStack(spacing: 20) {
                Button {
                    model.saveToPhotos()
                } label: {
                    Label("存相册", systemImage: "square.and.arrow.down")
                }
                Button {
                    showEditor = true
                } label: {
                    Label("去编辑", systemImage: "scissors")
                }
                Button(role: .destructive) {
                    model.discardRecording()
                } label: {
                    Label("放弃", systemImage: "trash")
                }
            }
            .buttonStyle(.bordered)
            .tint(.white)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(32)
    }

    // MARK: 降级态

    private var unauthorizedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill").font(.largeTitle)
            Text("需要相机权限").font(.headline)
            Text("请在 系统设置 → 隐私与安全性 → 相机 中允许 ChuanqiCut 访问。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("打开系统设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }

    private func fallbackView(text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash").font(.largeTitle)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }

    private struct CameraAlert: Identifiable {
        let message: String
        var id: String { message }
    }
}
