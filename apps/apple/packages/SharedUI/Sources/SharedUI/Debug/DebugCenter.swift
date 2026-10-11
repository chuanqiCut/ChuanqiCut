// SharedUI — 全局 DEBUG 诊断中心（ADR-0040；用户 2026-10-11：开关全局 + 全局存在）
//
// 职责：
//   * isVisible —— 全局浮层开关（持久化，跨屏共享：相机开着、进编辑器仍开）；
//   * 系统指标 2Hz 采样：内存足迹（phys_footprint）+ 进程 CPU%（proc_pidinfo
//     PROC_PIDTASKINFO 差分）——屏幕无关的全局量，各屏浮层直接渲染。
// 各屏特有数据（采集/渲染 fps、处理耗时、录制帧数）由各屏 VM 自采样，
// 与本中心的系统行在浮层里拼装。
//
// 线程模型：Timer 主线程；@Published 全主线程更新。
// 单位假设：pti_total_user/system 以纳秒累计（XNU proc_info 口径）——
// CPU% 显示加了 0...999 钳制，若真机上量纲不符（恒 0 或恒 999）一眼可见。

import Combine
import Darwin
import Foundation
import MachO
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

#if DEBUG

@MainActor
public final class DebugCenter: ObservableObject {

    /// 单例：UI 主线程驱动（Timer/读写全主线程），SharedUI 基座全局态惯例
    ///（与 App 内其他 ObservableObject 单例同型）。@MainActor 化会让
    /// nonisolated 存储初始化变复杂，这里以 `@MainActor` 类 + static let 完成。
    @MainActor public static let shared = DebugCenter()

    @Published public private(set) var isVisible: Bool
    @Published public private(set) var memoryMB: Double = -1
    @Published public private(set) var cpuPercent: Double = -1

    private var sampler: Timer?
    private var lastCpuTotal: Double = 0
    private var lastWallAt: DispatchTime?

    private static let visibilityKey = "debug.overlay.visible"

    private init() {
        // 未设置过 = 默认开（DEBUG 构建的诊断面板）；用户关过一次则尊重。
        // 未设置过 = 默认开（DEBUG 构建的诊断面板）；用户关过一次则尊重。
        if UserDefaults.standard.object(forKey: Self.visibilityKey) == nil {
            let env = ProcessInfo.processInfo.environment
            isVisible = env["CQ_DEBUG_OVERLAY"] == "1" || env["CQ_CAM_PROBE"] != nil
            UserDefaults.standard.set(isVisible, forKey: Self.visibilityKey)
        } else {
            isVisible = UserDefaults.standard.bool(forKey: Self.visibilityKey)
        }
        if isVisible { startSampler() }
    }

    public func toggle() {
        isVisible.toggle()
        UserDefaults.standard.set(isVisible, forKey: Self.visibilityKey)
        if isVisible { startSampler() } else { stopSampler() }
    }

    public func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        UserDefaults.standard.set(visible, forKey: Self.visibilityKey)
        if visible { startSampler() } else { stopSampler() }
    }

    private func startSampler() {
        guard sampler == nil else { return }
        lastCpuTotal = currentCpuTotal()
        lastWallAt = DispatchTime.now()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sampler = timer
    }

    private func stopSampler() {
        sampler?.invalidate()
        sampler = nil
    }

    private func sample() {
        // 内存：phys_footprint（jetsam 口径，与编辑器/相机剖面一致）。
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        memoryMB = kr == KERN_SUCCESS
            ? Double(info.phys_footprint) / 1_048_576.0 : -1

        // CPU%：PROC_PIDTASKINFO 累计时间差分 / 墙钟差分。
        let total = currentCpuTotal()
        let now = DispatchTime.now()
        if lastWallAt != nil, lastCpuTotal > 0, total >= lastCpuTotal {
            let wallNs = Double(now.uptimeNanoseconds &- lastWallAt!.uptimeNanoseconds)
            let cpuNs = total - lastCpuTotal
            let pct = wallNs > 0 ? cpuNs / wallNs * 100 : -1
            cpuPercent = min(max(pct, 0), 999)
        } else {
            cpuPercent = -1
        }
        lastCpuTotal = total
        lastWallAt = now
    }

    /// 进程 CPU 累计时间（秒）：task_threads() 枚举全部线程，逐线程
    /// THREAD_BASIC_INFO 累加 user/system（time_value_t = 秒+微秒）。
    /// 竞态防御：线程可在枚举与查询间退出——kr 失败的线程跳过（诚实降级）。
    private func currentCpuTotal() -> Double {
        var threads: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threads, &threadCount) == KERN_SUCCESS,
              let threadList = threads else {
            return lastCpuTotal
        }
        defer {
            let size = vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_act_t>.stride)
            _ = vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threadList)), size)
        }
        var total: Double = 0
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(
                MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threadList[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            guard kr == KERN_SUCCESS else { continue }
            total += Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
            total += Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
        }
        return total
    }
}

#endif
