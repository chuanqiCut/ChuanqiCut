// ChuanqiCut — 跨平台 ChqFrameProvider 头文件编译期自洽验证（MEDIA-010）
//
// 目的：
//   1. 证明 ChqFrameProvider 头文件自洽——能独立编译，include 顺序无关。
//   2. 证明零平台类型：只使用 base 层 + Platform 类型，编译单元内不出现任何平台类型
//      （由 check_platform_headers.py 门禁 + 评审兜底，本 TU 固化事实）。
//   3. 证明与 Platform ChqIFrameProvider 的分层：ChqFrameProvider 位于 Platform 之上，复用 Platform 的
//      ChqMediaSource / ChqMediaFrame / lease 模型与 base 的 ChqRationalTime / ChqStatus / ChqCancelToken。
//   4. 证明精确 seek 策略（ChqSeekPolicy）与取帧请求（ChqFrameRequest）契约成立。
//   5. 为下游留的钩子接口（ChqIFrameCache / ChqIDecoderPool）抽象、ChqDecoderHandle 为 opaque 指针。
//
// 注册为 ctest 用例（tests/CMakeLists.txt）。仅包含头文件 + static_assert，不链接实现。

#include <cstddef>
#include <type_traits>

// —— MEDIA 层头 ——
#include "cq/media/chq_frame_provider.h"

// Platform 与 base（ChqFrameProvider 之下依赖）。
#include "cq/platform/chq_common.h"
#include "cq/platform/chq_media.h"
#include "cq/base/chq_rational_time.h"
#include "cq/base/chq_status.h"
#include "cq/base/chq_concurrency.h"

namespace cq {
namespace {

// ---- 1. 精确 seek 策略枚举存在且默认枚举底层稳定（跨端一致）----
static_assert(sizeof(ChqSeekPolicy) == sizeof(int32_t), "ChqSeekPolicy must be int32_t stable");
static_assert(std::is_same_v<ChqSeekPolicy, decltype(ChqFrameRequest{}.policy)>,
              "ChqFrameRequest.policy must be ChqSeekPolicy");

// ---- 2. 取帧请求用 ChqRationalTime（时间统一，禁止浮点秒）----
static_assert(std::is_same_v<ChqRationalTime, decltype(ChqFrameRequest{}.at)>,
              "ChqFrameRequest.at must be ChqRationalTime, not double seconds");

// ---- 3. ChqFrameProvider 抽象、位于 Platform 之上、复用 Platform 类型 ----
static_assert(!std::is_default_constructible_v<ChqFrameProvider>,
              "ChqFrameProvider is abstract, implemented by MEDIA-020 ChqSystemFrameProvider");
// 复用 Platform ChqMediaSource / ChqMediaFrame（lease 模型一致）。
static_assert(std::is_same_v<ChqStatus (ChqFrameProvider::*)(const ChqMediaSource&),
                  decltype(&ChqFrameProvider::Open)>,
              "Open(ChqMediaSource&) must reuse Platform ChqMediaSource");
static_assert(std::is_same_v<void (ChqFrameProvider::*)(ChqMediaFrame&),
                  decltype(&ChqFrameProvider::ReleaseFrame)>,
              "ReleaseFrame(ChqMediaFrame&) matches Platform lease model");

// ---- 4. 精确 seek 语义签名：Seek(t, policy, token) ----
static_assert(std::is_same_v<ChqStatus (ChqFrameProvider::*)(const ChqRationalTime&, ChqSeekPolicy,
                  const ChqCancelToken&),
                  decltype(&ChqFrameProvider::Seek)>,
              "Seek(ChqRationalTime, ChqSeekPolicy, ChqCancelToken) signature must match");

// ---- 5. 取帧签名：AcquireFrame(ChqFrameRequest, ChqMediaFrame&, token) ----
static_assert(std::is_same_v<ChqStatus (ChqFrameProvider::*)(const ChqFrameRequest&, ChqMediaFrame&,
                  const ChqCancelToken&),
                  decltype(&ChqFrameProvider::AcquireFrame)>,
              "AcquireFrame(ChqFrameRequest, ChqMediaFrame&, ChqCancelToken) signature must match");

// ---- 6. 时长查询用 ChqRationalTime ----
static_assert(std::is_same_v<ChqStatus (ChqFrameProvider::*)(ChqRationalTime&) const,
                  decltype(&ChqFrameProvider::GetDuration)>,
              "GetDuration(ChqRationalTime&) must use ChqRationalTime, not double seconds");

// ---- 7. 下游钩子抽象且 ChqDecoderHandle 为 opaque 指针 ----
static_assert(!std::is_default_constructible_v<ChqIFrameCache>,
              "ChqIFrameCache is abstract (MEDIA-011 implements it)");
static_assert(!std::is_default_constructible_v<ChqIDecoderPool>,
              "ChqIDecoderPool is abstract (MEDIA-012 implements it)");
static_assert(std::is_pointer_v<ChqDecoderHandle>, "ChqDecoderHandle must be opaque pointer");
static_assert(std::is_same_v<ChqStatus (ChqIDecoderPool::*)(ChqCodecId, ChqDecoderHandle&),
                  decltype(&ChqIDecoderPool::AcquireDecoder)>,
              "AcquireDecoder(ChqCodecId, ChqDecoderHandle&) must use opaque decoder handle");

// ---- 8. 钩子注入点存在（MEDIA-011 帧缓存 / MEDIA-012 解码器池）----
static_assert(std::is_same_v<void (ChqFrameProvider::*)(ChqIFrameCache*),
                  decltype(&ChqFrameProvider::SetFrameCache)>,
              "SetFrameCache(ChqIFrameCache*) hook must exist (MEDIA-011)");
static_assert(std::is_same_v<void (ChqFrameProvider::*)(ChqIDecoderPool*),
                  decltype(&ChqFrameProvider::SetDecoderPool)>,
              "SetDecoderPool(ChqIDecoderPool*) hook must exist (MEDIA-012)");

}  // namespace
}  // namespace cq

int main() {
    // 编译期全部 static_assert 通过即代表头文件自洽、零平台类型、分层契约成立。
    return 0;
}
