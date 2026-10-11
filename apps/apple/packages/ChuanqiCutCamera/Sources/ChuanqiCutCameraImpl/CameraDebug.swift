// CameraDebug — 相机页 DEBUG 实时诊断（B-02 批，2026-10-11）
//
// 职责：采集 fps（帧交付）/ 渲染 fps（MTKView draw）/ 处理耗时（滤镜链+CI+MetalFX
// 单帧 ms）/ 录制帧数 / 内存足迹——「采集到上屏中间发生了什么」的可视化。
// 数据写入方：VM 帧 relay（captureTick）、CameraRenderer.draw（drawTick）；
// 读取方：VM 2Hz 采样 → CameraDebugOverlayView。全部 DEBUG only。

import Foundation
import SwiftUI
import SharedUI           // ADR-0040：共享诊断面板

#if DEBUG

/// 线程安全累计器（写入：采集/渲染线程；读取：VM 2Hz 采样）。
final class CameraDebugStats {
    private let lock = NSLock()
    private var captureCount: UInt64 = 0
    private var drawCount: UInt64 = 0
    private var processMsLast: Double = 0
    private var processMsWindowMax: Double = 0

    func captureTick() {
        lock.lock()
        captureCount += 1
        lock.unlock()
    }

    func drawTick(processMs: Double) {
        lock.lock()
        drawCount += 1
        processMsLast = processMs
        processMsWindowMax = max(processMsWindowMax, processMs)
        lock.unlock()
    }

    struct Snapshot {
        public let captureCount: UInt64
        public let drawCount: UInt64
        public let processMsLast: Double
        public let processMsWindowMax: Double
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(captureCount: captureCount, drawCount: drawCount,
                        processMsLast: processMsLast, processMsWindowMax: processMsWindowMax)
    }
}

/// 一次相机诊断采样（fps 由 VM 侧差分计算）。
public struct CameraDebugSnapshot: Equatable {
    public let captureFps: Double
    public let drawFps: Double
    public let processMsLast: Double
    public let processMsMax: Double
    public let isRecording: Bool
    public let recordedFrames: UInt64
    public let footprintMB: Double
    public let positionFront: Bool
}

struct CameraDebugOverlayView: View {
    let snapshot: CameraDebugSnapshot
    /// 系统行（内存/CPU）来自全局 DebugCenter（屏幕无关量）。
    @ObservedObject private var center = DebugCenter.shared

    var body: some View {
        DebugPanelView(title: header,
                       lines: lines + systemLines,
                       scrollable: true,
                       storageKey: "debug.camera",
                       contentMaxHeight: 240)
    }

    /// 系统行（全局 DebugCenter 采样）。
    private var systemLines: [String] {
        [
            "mem \(String(format: "%.0f", center.memoryMB))MB  cpu \(String(format: "%.0f", center.cpuPercent))%",
        ]
    }

    private var header: String {
        "\(snapshot.isRecording ? "⏺" : "○") \(snapshot.positionFront ? "前" : "后")摄"
    }

    private var lines: [String] {
        [
            "采集 \(fmt(snapshot.captureFps))/s  渲染 \(fmt(snapshot.drawFps))/s",
            "处理 \(String(format: "%.1f", snapshot.processMsLast))ms（窗口max \(String(format: "%.1f", snapshot.processMsMax))）",
            "录制帧 \(snapshot.recordedFrames)"
                + (snapshot.isRecording ? "（录制中）" : ""),
            "mem \(String(format: "%.0f", snapshot.footprintMB))MB",
        ]
    }

    private func fmt(_ v: Double) -> String {
        String(format: "%.0f", v)
    }
}

#endif
