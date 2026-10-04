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
        .onAppear { model.prepare() }
        .onChange(of: scenePhase) { _, newPhase in
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
                filterStrip
                recordBar
            }
            if let url = model.recordedURL {
                recordedPanel(url: url)
            }
        }
    }

    private var topBar: some View {
        HStack {
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
            .disabled(model.isRecording)
            .padding(.trailing, 20)
        }
        .padding(.top, 8)
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

    private var recordBar: some View {
        HStack {
            Spacer()
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
            Spacer()
        }
        .padding(.bottom, 28)
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
