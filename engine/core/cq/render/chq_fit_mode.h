// ChuanqiCut — 源帧 → 画布的宽高比适配模式（ADR-0018 / UIA-014）
//
// 为什么单独成头（不是"顺手抽个枚举"）：
//   它同时被**预览**（preview/）与 **RenderGraph**（render/，RENDER-001）消费。
//   继续放在 preview/chq_preview_renderer.h 里，render 层就得 include preview 头 ——
//   那是层次倒挂（预览是渲染的消费者，不是反过来），且会把 RenderGraph 绑死在
//   "预览专用"的语义上，导出（B4）就复用不了同一份装配代码（红线 #9）。
//
// 三种模式的**实现接缝**统一为「把全屏 blit 变换到一个矩形」（编码器视口）：
//   bar 区即清屏色（黑）；清屏不受视口影响，视口外无写入。
//   故三者共享同一条 GPU 路径，不是三套代码 —— 这是 ADR-0018 的备选取舍结论。

#ifndef CQ_CORE_RENDER_CHQ_FIT_MODE_H_
#define CQ_CORE_RENDER_CHQ_FIT_MODE_H_

#include <cstdint>

namespace cq {

enum class ChqFitMode : int32_t {
    kStretch = 0,  // 拉伸铺满（引入 ChqFitMode 前的既有行为，默认值）
    kContain = 1,  // 内切居中：letterbox / pillarbox，不裁内容
    kCover = 2,    // 外接居中：裁剪铺满，不留 bar
};

}  // namespace cq

#endif  // CQ_CORE_RENDER_CHQ_FIT_MODE_H_
