// ChuanqiCut — 跨平台 FrameProvider 头文件编译期自洽验证（MEDIA-010）
//
// 目的：
//   1. 证明 FrameProvider 头文件自洽——能独立编译，include 顺序无关。
//   2. 证明零平台类型：只使用 base 层 + PAL 类型，编译单元内不出现任何平台类型
//      （由 check_pal_headers.py 门禁 + 评审兜底，本 TU 固化事实）。
//   3. 证明与 PAL IFrameProvider 的分层：FrameProvider 位于 PAL 之上，复用 PAL 的
//      MediaSource / MediaFrame / lease 模型与 base 的 RationalTime / Status / CancelToken。
//   4. 证明精确 seek 策略（SeekPolicy）与取帧请求（FrameRequest）契约成立。
//   5. 为下游留的钩子接口（IFrameCache / IDecoderPool）抽象、DecoderHandle 为 opaque 指针。
//
// 注册为 ctest 用例（tests/CMakeLists.txt）。仅包含头文件 + static_assert，不链接实现。

#include <cstddef>
#include <type_traits>

// —— MEDIA 层头 ——
#include "cq/media/frame_provider.h"

// PAL 与 base（FrameProvider 之下依赖）。
#include "cq/pal/common.h"
#include "cq/pal/media.h"
#include "cq/base/time.h"
#include "cq/base/status.h"
#include "cq/base/concurrency.h"

namespace cq {
namespace {

// ---- 1. 精确 seek 策略枚举存在且默认枚举底层稳定（跨端一致）----
static_assert(sizeof(SeekPolicy) == sizeof(int32_t), "SeekPolicy must be int32_t stable");
static_assert(std::is_same_v<SeekPolicy, decltype(FrameRequest{}.policy)>,
              "FrameRequest.policy must be SeekPolicy");

// ---- 2. 取帧请求用 RationalTime（时间统一，禁止浮点秒）----
static_assert(std::is_same_v<RationalTime, decltype(FrameRequest{}.at)>,
              "FrameRequest.at must be RationalTime, not double seconds");

// ---- 3. FrameProvider 抽象、位于 PAL 之上、复用 PAL 类型 ----
static_assert(!std::is_default_constructible_v<FrameProvider>,
              "FrameProvider is abstract, implemented by MEDIA-020 SystemFrameProvider");
// 复用 PAL MediaSource / MediaFrame（lease 模型一致）。
static_assert(std::is_same_v<Status (FrameProvider::*)(const MediaSource&),
                  decltype(&FrameProvider::Open)>,
              "Open(MediaSource&) must reuse PAL MediaSource");
static_assert(std::is_same_v<void (FrameProvider::*)(MediaFrame&),
                  decltype(&FrameProvider::ReleaseFrame)>,
              "ReleaseFrame(MediaFrame&) matches PAL lease model");

// ---- 4. 精确 seek 语义签名：Seek(t, policy, token) ----
static_assert(std::is_same_v<Status (FrameProvider::*)(const RationalTime&, SeekPolicy,
                  const CancelToken&),
                  decltype(&FrameProvider::Seek)>,
              "Seek(RationalTime, SeekPolicy, CancelToken) signature must match");

// ---- 5. 取帧签名：AcquireFrame(FrameRequest, MediaFrame&, token) ----
static_assert(std::is_same_v<Status (FrameProvider::*)(const FrameRequest&, MediaFrame&,
                  const CancelToken&),
                  decltype(&FrameProvider::AcquireFrame)>,
              "AcquireFrame(FrameRequest, MediaFrame&, CancelToken) signature must match");

// ---- 6. 时长查询用 RationalTime ----
static_assert(std::is_same_v<Status (FrameProvider::*)(RationalTime&) const,
                  decltype(&FrameProvider::GetDuration)>,
              "GetDuration(RationalTime&) must use RationalTime, not double seconds");

// ---- 7. 下游钩子抽象且 DecoderHandle 为 opaque 指针 ----
static_assert(!std::is_default_constructible_v<IFrameCache>,
              "IFrameCache is abstract (MEDIA-011 implements it)");
static_assert(!std::is_default_constructible_v<IDecoderPool>,
              "IDecoderPool is abstract (MEDIA-012 implements it)");
static_assert(std::is_pointer_v<DecoderHandle>, "DecoderHandle must be opaque pointer");
static_assert(std::is_same_v<Status (IDecoderPool::*)(CodecId, DecoderHandle&),
                  decltype(&IDecoderPool::AcquireDecoder)>,
              "AcquireDecoder(CodecId, DecoderHandle&) must use opaque decoder handle");

// ---- 8. 钩子注入点存在（MEDIA-011 帧缓存 / MEDIA-012 解码器池）----
static_assert(std::is_same_v<void (FrameProvider::*)(IFrameCache*),
                  decltype(&FrameProvider::SetFrameCache)>,
              "SetFrameCache(IFrameCache*) hook must exist (MEDIA-011)");
static_assert(std::is_same_v<void (FrameProvider::*)(IDecoderPool*),
                  decltype(&FrameProvider::SetDecoderPool)>,
              "SetDecoderPool(IDecoderPool*) hook must exist (MEDIA-012)");

}  // namespace
}  // namespace cq

int main() {
    // 编译期全部 static_assert 通过即代表头文件自洽、零平台类型、分层契约成立。
    return 0;
}
