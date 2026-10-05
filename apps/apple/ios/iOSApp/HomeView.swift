// HomeView — 首页两入口（CAM-004，SPEC-CAM-001 v1.1）
//
// 纯导航壳：不持任何业务状态。EditorViewModel 的创建惰性化由 SharedUI 的
// EditorScreen 负责（进编辑器才建内核 Session，ADR-0014 存量耦合点的解法）。
// 相机页是 iOS 原生功能域（ADR-0014），本文件不 import AVFoundation。

import SwiftUI
import SharedUI
import ChuanqiCut

struct HomeView: View {

    private enum Route: Hashable {
        case editor
        case camera
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 28) {
                    Spacer()
                    titleBlock
                    Spacer()
                    entryCard(route: .editor,
                              title: "开始剪辑",
                              subtitle: "导入素材，剪辑你的故事",
                              icon: "film.stack")
                    entryCard(route: .camera,
                              title: "拍摄",
                              subtitle: "滤镜 · 实时预览 · 一键录制",
                              icon: "camera")
                    Spacer()
                    footerText
                }
                .padding(.horizontal, 32)
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .editor:
                    EditorScreen()
                case .camera:
                    CameraView()
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var titleBlock: some View {
        VStack(spacing: 6) {
            Text("ChuanqiCut")
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
            Text("拍 · 剪 · 出片")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func entryCard(route: Route, title: String, subtitle: String, icon: String) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private var footerText: some View {
        // 绑定层 API 是 ChuanqiCut.version（major/minor/patch 结构，无现成字符串）
        let v = ChuanqiCut.version
        return Text("ChuanqiCut SDK v\(v.major).\(v.minor).\(v.patch)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}
