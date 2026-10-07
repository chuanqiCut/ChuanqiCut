// ChuanqiCut — Swift 调用链路的**独立**验收（BIND-002）
//
// 为什么不用 XCTest/SPM 跑：
//   SwiftPM 6.1 在本机解析本项目的 xcframework 时报 “unexpected binary framework”，
//   进而库搜索路径失效（ld: library 'ChuanqiCut' not found），`swift test` 链接不过。
//   这是**打包/集成层**的问题，不是 Swift 绑定代码的问题 —— 因此这里用 swiftc
//   直接编译 + 显式链接静态库，把"Swift 能不能真调用内核"这件事单独验清楚。
//
// 运行：bindings/swift/run_smoke.sh

import CChuanqiCut
import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if !cond {
        failures += 1
        print("  FAIL: \(msg)")
    }
}

// ---- 版本 ----
let v = ChuanqiCut.version
print("version: \(v.major).\(v.minor).\(v.patch)")

// ---- 主线程标记（XCTest 之外也要能验；这里是普通可执行入口）----
ChuanqiCut.markMainThread()
check(ChuanqiCut.isMainThread, "markMainThread 后 isMainThread 为真")

// ---- 能力查询：未安装后端 -> .no（安全默认）----
check(ChuanqiCut.queryCapability(.hwDecodeH264) == .no, "未安装后端时能力为 no")
check(ChuanqiCut.queryCapability(.gpuMetal) == .no, "未安装后端时 gpuMetal 为 no")

// ---- 状态码语义 ----
check(Status.ok.isOK, "ok 是成功")
check(Status.cancelled.isCancelled && !Status.cancelled.isError, "取消不是错误")

// ---- 会话端到端 ----
guard let session = Session() else {
    print("FAIL: Session 创建失败")
    exit(1)
}
check(session.currentSnapshot.version == 0, "初始版本为 0")

let st = session.submit("add-clip") { .ok }
check(st == .ok, "submit 成功入队")

let deadline = Date().addingTimeInterval(5)
while session.currentSnapshot.version < 1 && Date() < deadline {
    Thread.sleep(forTimeInterval: 0.01)
}
check(session.currentSnapshot.version == 1, "成功变更后版本为 1")
check(session.changeCount == 1, "变更记录数为 1")

let changes = session.changesSince(0)
check(changes.count == 1, "changesSince 返回 1 条")
check(changes.first?.version == 1, "变更版本为 1")
check(changes.first?.name == "add-clip", "变更名可取回（静态字符串未悬垂）")
check(session.changesSince(1).isEmpty, "最新版本之后无变更")

// ---- 失败变更不推进版本 ----
session.submit("bad") { .invalidArgument }
Thread.sleep(forTimeInterval: 0.1)
check(session.currentSnapshot.version == 1, "失败变更后版本仍为 1")
check(session.changeCount == 1, "失败变更不计入日志")

// ---- 观察者 ----
// ⚠️ 刻意不用 .main：主线程正阻塞在 semaphore 上，默认队列会自锁。
//    这也顺带验证了「观察队列可配置」这一点。
let sem = DispatchSemaphore(value: 0)
let box = ObservedBox()
session.setSnapshotObserver(queue: DispatchQueue.global()) { snap in
    box.version = snap.version
    sem.signal()
}
session.submit("second") { .ok }
_ = sem.wait(timeout: .now() + 5)
check(box.version == 2, "观察者收到递增后的版本 2")

// ---- 预览（BIND-003 子步骤 6；UIA-009 子步骤 2 收口后挂 session）----
// 链接级 + 契约级证明：cq_preview_* 在库内且可调用；空隙帧语义正确
// （kIoNotFound + 仍返回清屏黑的可显示句柄）。像素级验证在 SharedUI 测试
// （离屏 RT 是 private 存储，读回要走 blit，由 PreviewFrameRenderer 的测试做）。
guard let previewSession = Session() else {
    print("FAIL: 预览用 Session 创建失败")
    exit(1)
}
guard let preview = Previewer(session: previewSession, width: 64, height: 64) else {
    print("FAIL: Preview 创建失败（PAL 预览后端缺失或设备创建失败）")
    exit(1)
}
check(preview.renderFrame(pts: RationalTime(value: 60000, timescale: 120000)) == .ioNotFound,
      "空时间线渲染返回 ioNotFound")
check(preview.textureHandle != nil, "空隙帧仍返回可显示句柄（清屏黑）")
check(!preview.lastHitClip, "空时间线未命中片段")
check(preview.lastFramePts == RationalTime(value: 0, timescale: 1),
      "无帧记录时 last_frame_pts 为内核初值 0/1")
check(preview.lastCpuFallback == false, "无导入即无 CPU 退化")

print(failures == 0 ? "PASSED" : "FAILED (\(failures) failures)")
exit(failures == 0 ? 0 : 1)

/// @Sendable 回调里不能捕获 `var`，用盒子承接。
final class ObservedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    var version: UInt64 {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
}
