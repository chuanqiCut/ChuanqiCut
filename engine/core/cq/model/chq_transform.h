// ChuanqiCut — 空间 / 层级 / 变速 / 关键帧数据槽（MODEL-004，B5.5 第一块）
//
// 本文件做什么（ADR-0040 §2 的字段清单，RESEARCH-016 §2.3 的缺口表）：
//   * `ChqTransform` —— 位移 / 缩放 / 旋转 / 镜像 / 相对尺寸 / 不透明度，挂到 clip 与 track；
//   * `ChqSpeed` —— 变速比（**整数比**，不是浮点倍速，理由见下"时间语义"）；
//   * `ChqKeyframe` / `ChqKeyframeList` —— 关键帧 = 时刻 + **属性子集快照**（不拷整个 clip）；
//   * `layer` 的取值域与校验 —— 叠放次序从此用显式整数表达，不再靠数组顺序。
//
// 本文件**不**做什么（有意留白，不要假装已有）：
//   * 不消费这些字段做渲染 —— 变换节点归 RENDER-010，多轨叠合归 RENDER-011；
//   * 不做 UI 交互 —— 归 B6/B7；写路径的 Command 在 `command/chq_command.h`；
//   * 不做关键帧插值引擎 —— 归 anim 模块（B8）。本卡只保证"存得进、验得了、指纹盖得住"。
//
// 坐标约定（不得另立一套，改代码前先读）：
//   * 原点 = 画布**左上**，x 向右、y 向下 —— 与 `platform/chq_gfx.h` 的 viewport 同一**方向**口径
//     （现成描述见 `engine/platform/apple/gfx/gfx_metal.mm:317`；单位不同：viewport 是像素，这里是归一化占比）。
//   * `translate_* / scale_* / relative_* / opacity` 一律 **float**、归一化到画布
//     （1.0 = 一个画布宽或高）。非时间量允许浮点，与 `chq_property.h` 同族先例；
//     契约头门禁（`tools/platform/check_platform_headers.py`）禁 double token。
//   * `rotation_degrees` 正值 = 从 +x 轴向 +y 轴转。本约定下 y 向下，故**屏幕观感是顺时针**。
//
// 时间语义（红线 #4，本文件唯一涉及时间的地方是关键帧时刻）：
//   * 变速**不存浮点倍速**：时间线占时由 `ScaleRational(source_duration, den, num)` 精确导出。
//     浮点倍速会在奇数源时长上引入取整误差，且不可逆 —— 对标平台把 `NSTimeInterval` 当微秒用
//     的教训（RESEARCH-016）不得复现。UI 若要 1.5x，写入前先归成比 3/2。
//   * 关键帧的 `values` 是属性袋，**里面没有时间**（沿用 chq_property.h 的"时间不进属性"）；
//     时刻本身用 `ChqRationalTime`。
//   * 关键帧时刻 = **相对片段起点**（不是时间线绝对时刻）：拖动片段不该改变动画相位。
//     求值方先算 `at - clip.start` 再查表。负时刻被 `ChqKeyframeList::Set` 拒绝 ——
//     局部时间里"片段开始之前"的帧永远采不到，留着只是假数据。
//     ⚠️ 裁剪（trim-in）要不要把帧跟着媒体一起平移，本卡没定：归 B8（anim）。
//   * 不设拍脑袋上界：倍速比与层级只做"必须为正 / 必须落在 [kLayerMin, kLayerMax]"这类
//     语义域检查，乘算溢出交给 `ScaleRational` 的 `kOverflow`（它本来就在检测 int64）。

#ifndef CQ_CORE_MODEL_CHQ_TRANSFORM_H_
#define CQ_CORE_MODEL_CHQ_TRANSFORM_H_

#include <cstdint>
#include <vector>

#include "cq/base/chq_rational_time.h"
#include "cq/base/chq_status.h"
#include "cq/model/chq_property.h"

namespace cq {

// 镜像：沿用对标口径的三值编码（0 正常 / 1 水平 / 2 垂直）。
// 有意不做"水平+垂直"组合位 —— 组合等价于 180° 旋转，加进来会让"恒等"判定多一个自由度。
enum class ChqMirrorKind : int32_t {
    kNone = 0,
    kHorizontal = 1,
    kVertical = 2,
};

// 渲染层级取值域。上界沿用对标平台 `layer(0~1000)` 的口径（RESEARCH-016 §2.3）——
// 它是**语义域**而不是性能阈值：超过 1000 层叠放不是产品能力，写错成 INT32 巨值倒是真事。
constexpr int32_t kLayerMin = 0;
constexpr int32_t kLayerMax = 1000;

// ---------------------------------------------------------------------------
// ChqTransform — 一个实体的空间状态
// ---------------------------------------------------------------------------
// 默认构造**必须**是恒等变换（IsIdentity() == true）：新建 clip 不填 transform 时
// 渲染结果与改动前逐像素一致 —— B5.5 是回归型地基，看得出来就是 bug。
struct ChqTransform {
    float translate_x = 0.0f;  // 归一化到画布宽（左上原点，+x 向右）
    float translate_y = 0.0f;  // 归一化到画布高（+y 向下）
    float scale_x = 1.0f;      // 1.0 = 不缩放
    float scale_y = 1.0f;
    float rotation_degrees = 0.0f;  // 正值 = 屏幕观感顺时针（见文件头坐标约定）
    ChqMirrorKind mirror = ChqMirrorKind::kNone;
    float relative_width = 1.0f;   // 相对 parent（= 画布）的宽占比
    float relative_height = 1.0f;  // 相对 parent 的高占比
    float opacity = 1.0f;          // 逐层不透明度（RENDER-011 叠合读它）

    // 恒等判定：所有字段都在"不改画面"的值上（scale 1 / relative 1 / opacity 1 / 其余 0 / kNone）。
    bool IsIdentity() const;

    // 语义域校验：scale / relative / opacity 必须有限且为正（opacity 另限 ≤1）；
    // mirror 必须是三个已知值之一。违规 → kInvalidArgument。
    // NaN 也要拦住：`x == x` 为假，所以用有限性判定而不是范围比较。
    ChqStatus Validate() const;

    // 结构指纹（FNV-1a 64），供模型 digest 混合。同一份内容必须每次算出同一个值，
    // 因此按字段的**位模式**混合（不做浮点算术，避免 -ffast-math 一类开关改变指纹）。
    uint64_t Fingerprint() const;

    // 改画布比例时同步修正相对尺寸（保持**像素宽高不变**）：
    //   relative_width'  = relative_width  * (old_w / new_w)
    //   relative_height' = relative_height * (old_h / new_h)
    // 对标平台的 `setCanvasRatioWithUpdateRelativeLocation:` 注释明说不同步修正
    // 「子元素会错乱」—— 本仓由 `ChqTimeline::SetCanvas` 调用它来回答同一个问题
    // （单测 `model_transform` 锁死）。old/new 任一非正 → kInvalidArgument。
    ChqStatus RescaleRelativeTo(int32_t old_width, int32_t old_height, int32_t new_width,
                                int32_t new_height);

    bool operator==(const ChqTransform&) const = default;
    bool operator!=(const ChqTransform& o) const { return !(*this == o); }
};

// ---------------------------------------------------------------------------
// ChqSpeed — 变速比（num / den，均为正整数）
// ---------------------------------------------------------------------------
struct ChqSpeed {
    int32_t numerator = 1;    // 2x 写作 {2, 1}
    int32_t denominator = 1;  // 0.5x 写作 {1, 2}

    // num > 0 且 den > 0；否则 kInvalidArgument（acceptance：speed <= 0 一律拒绝）。
    ChqStatus Validate() const;

    // 由源时长导出时间线占时：out = source_duration * (den / num)。
    // 精确有理数；溢出 → kOverflow（来自 ScaleRational）。
    ChqStatus ApplyTo(const ChqRationalTime& source_duration, ChqRationalTime& out) const;

    bool operator==(const ChqSpeed&) const = default;
    bool operator!=(const ChqSpeed& o) const { return !(*this == o); }
    uint64_t Fingerprint() const;
};

// ---------------------------------------------------------------------------
// ChqKeyframe — 单个关键帧 = 时刻 + 属性子集
// ---------------------------------------------------------------------------
// 粒度是**按 key 的属性快照**，不是实体副本：对标平台让关键帧克隆整个 Slot
// （`createKeyframe`），任意属性自动获得关键帧能力，代价是内存膨胀。
// 本仓有属性袋（MODEL-003），按 key 快照更省且插值时按 key 逐条算。
struct ChqKeyframe {
    ChqRationalTime time;  // 相对片段起点（见文件头"时间语义"），非负
    ChqPropertyBag values;

    bool operator==(const ChqKeyframe& o) const {
        return time == o.time && values == o.values;
    }
    bool operator!=(const ChqKeyframe& o) const { return !(*this == o); }
    uint64_t Fingerprint() const;
};

// ---------------------------------------------------------------------------
// ChqKeyframeList — 一个通道上的关键帧序列（按时刻升序维护）
// ---------------------------------------------------------------------------
class ChqKeyframeList {
public:
    // 按时刻覆盖写：同刻已有 = 替换 values，没有 = 插入并保持升序。
    // 空袋拒绝（kInvalidArgument）—— 空关键帧既不能展示也不能插值，只会让
    // "有没有这条通道"变成含糊问题。时刻非法（timescale <= 0 或负值 = 片段开始之前）
    // 同样拒绝。
    ChqStatus Set(const ChqRationalTime& time, const ChqPropertyBag& values);

    // 按时刻删除。不存在 → kIoNotFound（如实区分"参数不对"与"没这一帧"）。
    ChqStatus Erase(const ChqRationalTime& time);

    const ChqKeyframe* Find(const ChqRationalTime& time) const;

    size_t Size() const { return frames_.size(); }
    bool Empty() const { return frames_.empty(); }
    void Clear() { frames_.clear(); }

    // 只读遍历（渲染/UI 查询用；升序 = 求值顺序稳定）。
    const std::vector<ChqKeyframe>& Frames() const { return frames_; }

    bool operator==(const ChqKeyframeList& o) const { return frames_ == o.frames_; }
    bool operator!=(const ChqKeyframeList& o) const { return !(*this == o); }

    // 结构指纹（按帧序混合；升序维护 ⇒ 与插入历史无关）。
    uint64_t Fingerprint() const;

private:
    std::vector<ChqKeyframe> frames_;  // 按 time 升序（Set 维护这个不变量）
};

}  // namespace cq

#endif  // CQ_CORE_MODEL_CHQ_TRANSFORM_H_
