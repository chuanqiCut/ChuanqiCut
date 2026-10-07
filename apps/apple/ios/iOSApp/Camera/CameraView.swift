// CameraView — 相机页（CAM-004，ADR-0014：iOS 专属，不进 MacApp）
//
// 结构：预览铺满 + 顶部翻转钮 + 底部（滤镜条 + 录制钮）+ 录制产物面板。
// 权限拒绝态明示引导（SPEC-CAM-001 v1.1 A6：不闪退、给出路）。

import AVFoundation
import SwiftUI
import SharedUI

struct CameraView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: CameraViewModel
    @State private var showEditor = false
    @State private var showBeautyPanel = false

    init() {
        // 先建值后包装（pitfalls P8 同款）：构造不再抛错，Metal 不可用由
        // renderer == nil 的降级文案兜底。
        _model = StateObject(wrappedValue: CameraViewModel())
    }

    var body: some View {
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
            EditorScreen(initialMediaURL: model.recordedURL)
                .onDisappear { model.discardRecording() }
                // 录制产物进编辑器且不保留本地临时文件语义：导入后放弃临时文件。
                // （importMedia 走原路径引用，见 UIA-009 的 D3 决策。）
        }
    }

    // MARK: 运行态

    private var runningView: some View {
        ZStack {
            if let renderer = model.renderer {
                CameraVideoView(renderer: renderer)
                    .ignoresSafeArea()
            }
            VStack {
                topBar
                Spacer()
                modePicker
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
    }

    private var topBar: some View {
        HStack {
            Button {
                showBeautyPanel = true
            } label: {
                Image(systemName: model.beauty.isOff ? "face.dashed" : "face.smiling")
                    .font(.title2)
                    .foregroundStyle(model.beauty.isOff ? .white : .yellow)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .disabled(model.isRecording)
            Spacer()
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
        .padding(.top, 8)
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

    // MARK: 美颜面板（磨皮/美白即时生效；美型归 B 期 CAM-012/013，如实标注）

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
                Text("美型").frame(width: 44, alignment: .leading)
                    .foregroundStyle(.tertiary)
                Text("瘦脸 / 大眼 · B 期上线（依赖人脸关键点网格形变）")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            HStack {
                Button("重置") {
                    model.beauty = .off
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
