// ChuanqiCut — 跨端一致错误码体系（CORE-002）
//
// 设计约束（来自 ARCH-001 / AGENTS.root.md 红线）：
//   1. 头文件零平台类型：本文件只使用 C/C++ 基础整数类型与 `const char*`，
//      绝不出现任何 Apple/Android/鸿蒙平台类型。
//   2. 内核禁用异常（ARCH-001：「禁用异常跨模块」；SDK C ABI「无异常」）。
//      错误一律通过 `Status` 返回值传播，绝不用 throw / catch。
//   3. 错误码必须是**稳定数值**，跨端（iOS / macOS / Android / HarmonyOS / 桌面）一致。
//      因此 `StatusCode` 的每个枚举值都显式写死，绝不依赖编译器自动编号
//      （自动编号会在中间插入新码时让后续码值整体平移，破坏跨端一致性）。
//      底层固定为 `int32_t`，保证三端 ABI 下位宽一致、序列化稳定。
//
// 与 CORE-005 CancelToken 的取消语义分界（约定，CORE-005 尚未实现）：
//   - `kCancelled` 是一个**独立的「停止信号」码值，而不是「错误」**。
//   - 「取消」表示任务被用户/系统主动中止，属于正常控制流；
//     「错误」表示任务因故障无法完成。二者语义不同，调用方必须区分对待：
//       * `IsError()` 对 `kCancelled` 返回 **false**（取消不是错误）。
//       * `IsCancelled()` 专门用于识别取消。
//   - CORE-005 的 `CancelToken` 将来只会产生 `kCancelled`；
//     任何长任务函数在检测到取消时应返回 `kCancelled`，而不是把它
//     混进 `kInternal` / `kUnknown` 之类的错误码。
//   - 调用方约定：收到 `kCancelled` 后做清理并正常退出，不计入失败统计、
//     不弹「出错」提示；收到其它非 OK 码才视为失败。

#ifndef CQ_BASE_STATUS_H_
#define CQ_BASE_STATUS_H_

#include <cstdint>

namespace cq {

// 错误码分类（与 StatusCode 的数值区间一一对应）。
// 用于日志聚合、分类上报，不影响跨端码值稳定性。
enum class StatusCategory : int32_t {
    kOk = 0,            // 成功
    kIo = 1,            // I/O：文件/网络/设备等读写失败
    kDecode = 2,        // 解码：媒体解码失败或不支持的解码路径
    kEncode = 3,        // 编码：媒体编码失败或不支持的编码路径
    kFormat = 4,        // 格式：容器/编码格式不被支持（区别于解码路径失败）
    kResource = 5,      // 资源不足：内存/句柄/纹理预算耗尽等
    kCancelled = 6,     // 取消（非错误，独立控制流信号）
    kInvalidArgument = 7, // 参数非法：调用方传入了不合法的参数
    kNumeric = 8,       // 数值溢出：有理数/坐标运算越界（CORE-001 复用）
    kInternal = 9,      // 内部错误：不应发生的内部不一致
    kUnknown = 10,      // 未知：兜底
    kAiPlan = 11,       // AI 决策：EditPlan 校验失败（9500..9549，AIEDIT-001）
};

// 稳定错误码。每个值显式写死，新增码必须追加到各自区间的「尾部间隙」，
// 不得插入已有码之间，以保证已发布码值的跨端稳定性。
enum class StatusCode : int32_t {
    kOk = 0,

    // ---- I/O（1000..1099）----
    kIoError = 1000,        // 通用 I/O 错误
    kIoNotFound = 1001,     // 资源不存在（文件/资产缺失）
    kIoPermission = 1002,   // 权限不足
    kIoTimeout = 1003,      // 读写超时

    // ---- 解码（2000..2099）----
    kDecodeError = 2000,        // 通用解码失败
    kDecodeUnsupported = 2001,  // 编码格式/配置不被解码器支持
    kDecodeNoKeyframe = 2002,   // 缺少关键帧，无法解码（seek 边界）

    // ---- 编码（3000..3099）----
    kEncodeError = 3000,        // 通用编码失败
    kEncodeUnsupported = 3001,  // 编码格式/配置不被编码器支持

    // ---- 格式（4000..4099）----
    kFormatUnsupported = 4000,  // 容器/封装格式不被支持

    // ---- 资源不足（5000..5099）----
    kResourceExhausted = 5000,  // 内存/句柄/纹理预算等耗尽

    // ---- 取消（6000..6099）：非错误，独立信号 ----
    kCancelled = 6000,

    // ---- 参数非法（7000..7099）----
    kInvalidArgument = 7000,

    // ---- 数值溢出（8000..8099）----
    kOverflow = 8000,

    // ---- 内部错误（9000..9099）----
    kInternal = 9000,

    // ---- AI 决策 / EditPlan 校验（9500..9549，AIEDIT-001，CQ_AI_PLAN_* 语义段）----
    // 校验器是 LLM 输出的唯一权威校验方（ADR-0020 决策 3）；
    // 码值同时是 golden 样例集的断言目标（tests/unit/test_edit_plan_validator.cpp），
    // 供管线（AIEDIT-005）按码分类回传 LLM 自动修复。
    kAiPlanJsonMalformed = 9500,        // JSON 语法非法（RFC 8259）
    kAiPlanSchemaUnknown = 9501,        // schema 版本不认识（拒绝并降级，绝不猜测解析）
    kAiPlanFieldMissing = 9502,         // 必填字段缺失
    kAiPlanFieldType = 9503,            // 字段 JSON 类型错误
    kAiPlanFloatTime = 9504,            // 时间字段出现浮点（红线 4 的机器检查）
    kAiPlanTimescaleMismatch = 9505,    // 时间对象 timescale != 120000（kProjectTimeScale）
    kAiPlanTimeNonPositive = 9506,      // 时间值非法（负值 / 要求为正的时长非正）
    kAiPlanUnknownOp = 9507,            // 未知动词（有界动词集之外）
    kAiPlanAssetUnknown = 9508,         // asset_id 引用不存在（对照 FeatureReport 资产表）
    kAiPlanShotOutOfRange = 9509,       // shot 序号越界（<0 或 >= shot_count）
    kAiPlanSourceRange = 9510,          // source_in + duration 越过素材时长（含溢出防御）
    kAiPlanTimelineOverlap = 9511,      // place_clip 时间线段重叠
    kAiPlanReorderNotPermutation = 9512,// reorder 非排列（重复/越界/长度不符）
    kAiPlanTransitionKindUnknown = 9513,// 未知转场类型（不在 model TransitionKind 对应集）

    // ---- 未知（9900..）----
    kUnknown = 9900,
};

// 轻量状态值。仅含一个稳定枚举码，零堆分配、零平台类型，
// 可在音频线程（无锁、无分配要求）安全拷贝与返回。
// 不携带可变文本消息：日志文本由 `StatusToString` 在日志侧按需生成，
// 避免在内核热路径引入字符串分配。
struct Status {
    StatusCode code = StatusCode::kOk;

    constexpr Status() = default;
    constexpr explicit Status(StatusCode c) : code(c) {}

    // 成功构造的便捷方式。
    static constexpr Status Ok() { return Status{}; }

    constexpr bool IsOk() const { return code == StatusCode::kOk; }

    // 是否「错误」（取消不计入错误，见文件头分界约定）。
    // 注意：仅 kOk 与 kCancelled 不算错误；其余非 Ok 码均为错误。
    constexpr bool IsError() const {
        return code != StatusCode::kOk && code != StatusCode::kCancelled;
    }

    // 是否「被取消」（独立的控制流信号，不是错误）。
    constexpr bool IsCancelled() const { return code == StatusCode::kCancelled; }

    // 便于在条件里当布尔用：`if (status) { ... }` 表示成功。
    constexpr explicit operator bool() const { return code == StatusCode::kOk; }

    constexpr bool operator==(const Status& other) const { return code == other.code; }
    constexpr bool operator!=(const Status& other) const { return code != other.code; }
};

// 返回码值对应的可读字符串（仅用于日志/UI 展示，禁止进入计算路径）。
// 返回的指针指向静态存储，调用方无需释放。
const char* StatusToString(StatusCode code);

// 返回码值所属的分类（用于日志聚合 / 分类上报）。
StatusCategory CategoryOf(StatusCode code);

}  // namespace cq

#endif  // CQ_BASE_STATUS_H_
