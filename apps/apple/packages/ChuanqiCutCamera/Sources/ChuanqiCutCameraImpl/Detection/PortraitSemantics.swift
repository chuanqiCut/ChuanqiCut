// PortraitSemantics — 人像语义蒙版调度（CAM-027 实现层薄壳）
//
// 分工（CAM-012/019/026 一贯的分层）：
//   - 算法在**契约层** `PortraitSkinMask`（macOS 可 typecheck、可单测）；
//   - 本文件只做三件事：绑定当前帧锚点、安装注入点、**诚实降级**。
//
// 为什么走「注入点」而不是改 CameraBeauty 签名：TASK-CAM-027 卡写明「API 形状保持
// `apply(to:faces:)` 不变、调用方零改动」。给 CameraBeauty 加参数是违规的 ——
// 上一会话正是这么写的，而且还引用了不存在的符号 → 整包编不过（P89）。
// 注入点与既有 `CameraBeautyEngine.smoothing` 同款：不装 = 老路径，逐位等价。
//
// 调度纪律（全部复用检测桥的现成约定，不新建状态、不起线程）：
//   - 锚点直接读 FaceBoxStore（检测队列写、渲染/录制线程读，内部 NSLock 串行化，
//     语义是「最新一帧」latest-wins）。
//   - 蒙版是 CI 惰性 DAG：这里只搭图、不求值，真正的三角光栅化发生在渲染取帧时；
//     不缓存、不预生成。若真机实测成为热点，再按 profiler 数据决定要不要复用。
//   - 锚点缺失（无脸 / 降级）→ `PortraitSkinMask` 返回框级蒙版 → 不伪造语义。

import CoreImage
import Foundation

// FaceBoxStore 本来就是一个「带锁的跨线程盒子」（检测队列写、渲染/录制线程读），
// 这里补 @unchecked Sendable 只是为了让它能合法出现在 @Sendable 闭包里 ——
// **不是新开的口子**：所有可变成员都由内部 NSLock 串行化
// （见 CameraRenderer 中的 FaceBoxStore 实现，每个访问点都成对 lock/unlock）。
extension FaceBoxStore: @unchecked Sendable {}

enum PortraitSemantics {

    /// 安装皮肤蒙版到美颜契约层。主线程调用一次（ViewModel 装配期）。
    /// 闭包体会在**渲染/录制线程**执行 → 只准读 `FaceBoxStore` 带锁的最新值。
    static func installSkinMask(faceBoxStore: FaceBoxStore) {
        CameraBeautyEngine.semanticMask = { image, boxes in
            PortraitSkinMask.skinMask(for: image, faceBoxes: boxes,
                                      anchors: faceBoxStore.currentMakeupAnchors())
        }
    }

    /// 摘掉注入点（复位 / 未注入侧）：回到 CAM-019 框级椭圆蒙版。
    static func uninstallSkinMask() {
        CameraBeautyEngine.semanticMask = nil
    }
}
