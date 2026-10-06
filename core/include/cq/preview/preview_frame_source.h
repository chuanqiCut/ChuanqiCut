// ChuanqiCut — 预览帧源抽象（UIA-010 子步骤 5）
//
// 为什么要有这层抽象（不是为了"面向接口编程"的洁癖）：
//   `PreviewRenderer` 的真实实现依赖 Metal + 硬解后端，单帧耗时由解码速度决定、
//   且必须真跑一遍才有结果。用它测「请求合并 / 丢帧计数 / 渲染发生在哪条线程」
//   这类**并发语义**既慢又不确定（结果随机器负载漂移）。
//   抽出一个「渲染一帧」的接缝后，预览泵（PreviewPump）可以被注入假实现，
//   用可控的 sleep 把并发语义测成确定性断言。
//
// 与 PreviewRenderer 的关系：PreviewRenderer 是**唯一**的真实实现者；
// 本接口不引入任何新的渲染语义，只是把已有方法显式化。

#ifndef CQ_PREVIEW_PREVIEW_FRAME_SOURCE_H_
#define CQ_PREVIEW_PREVIEW_FRAME_SOURCE_H_

#include <cstdint>

#include "cq/base/concurrency.h"  // CancelToken
#include "cq/base/status.h"
#include "cq/base/time.h"  // RationalTime
#include "cq/pal/common.h"  // TextureHandle
#include "cq/pal/gfx.h"  // IRenderTarget

namespace cq {

class IPreviewFrameSource {
public:
    virtual ~IPreviewFrameSource() = default;

    // 渲染 pts 处一帧到离屏目标；out_texture = 目标背后的纹理句柄（中性句柄）。
    // 语义与 PreviewRenderer::RenderFrame 完全一致（含 kIoNotFound 表示空隙）。
    virtual Status RenderFrame(const RationalTime& pts, TextureHandle& out_texture,
                              const CancelToken& token) = 0;

    // 改变离屏目标尺寸（会丢弃旧目标与其纹理句柄）。
    virtual Status Resize(uint32_t width, uint32_t height) = 0;

    // 当前离屏目标（测试读回像素用；UI 侧不需要）。
    virtual IRenderTarget* Target() = 0;

#ifndef NDEBUG
    // MEDIA-023 排障仪器（仅 Debug 构建）：上一帧分段耗时（acquire/import/draw/
    // total，纳秒）。无仪器的实现返回 nullptr（泵据此跳过汇总）。
    struct StageTimings {
        int64_t acquire_ns = 0;
        int64_t import_ns = 0;
        int64_t draw_ns = 0;
        int64_t total_ns = 0;
    };
    virtual const StageTimings* DebugLastTimings() const { return nullptr; }
    // MEDIA-026 看门狗：当前渲染阶段名（空串 = 空闲）。无仪器的实现返回空。
    virtual const char* DebugStage() const { return ""; }
    virtual int64_t DebugStageSinceNanos() const { return 0; }
#endif
};

}  // namespace cq

#endif  // CQ_PREVIEW_PREVIEW_FRAME_SOURCE_H_
