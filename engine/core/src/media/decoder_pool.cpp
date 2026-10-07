// ChuanqiCut — MEDIA-012 DecoderPool 实现（跨平台层）
//
// 头文件零平台类型 / 零 FFmpeg 类型 / 无异常。细节见 decoder_pool.h（降级策略 / 硬解路数）。

#include "cq/media/decoder_pool.h"

namespace cq {

DecoderPool::DecoderPool(int32_t max_hardware_paths,
                         std::unique_ptr<IDecoderFactory> factory)
    : max_hardware_paths_(max_hardware_paths > 0 ? max_hardware_paths
                                                 : kDefaultMaxHardwarePaths),
      factory_(std::move(factory)) {}

Status DecoderPool::AcquireDecoder(CodecId codec, DecoderHandle& out_decoder) {
    std::lock_guard<std::mutex> lk(mtx_);
    out_decoder = nullptr;

    // 1) 复用空闲同 codec 解码器（不新建硬解 session）。
    for (auto& s : slots_) {
        if (!s.in_use && s.codec == codec) {
            s.in_use = true;
            out_decoder = s.handle;
            return Status::Ok();
        }
    }

    // 2) 新建一路（路数未满）。
    int32_t active = 0;
    for (const auto& s : slots_) {
        if (s.in_use) ++active;
    }
    if (active < max_hardware_paths_ && factory_ != nullptr) {
        DecoderHandle h = nullptr;
        Status st = factory_->Create(codec, h);
        if (!st.IsOk()) return st;  // 工厂失败如实上报，不崩溃
        Slot slot{h, codec, /*in_use=*/true};
        slots_.push_back(slot);
        out_decoder = h;
        return Status::Ok();
    }

    // 3) 满且无空闲 → 降级：返回 kResourceExhausted（非错误计数、非崩溃、非挂起）。
    //    调用方据此背压/排队；不在此阻塞等待（避免 CORE-005 条件变量挂死）。
    return Status{StatusCode::kResourceExhausted};
}

void DecoderPool::ReleaseDecoder(DecoderHandle decoder) {
    std::lock_guard<std::mutex> lk(mtx_);
    for (auto& s : slots_) {
        if (s.handle == decoder) {
            s.in_use = false;  // 置空闲，可复用，不销毁
            return;
        }
    }
    // 未知 handle：忽略（防御，不崩溃）
}

int32_t DecoderPool::ActiveCount() const {
    std::lock_guard<std::mutex> lk(mtx_);
    int32_t n = 0;
    for (const auto& s : slots_) {
        if (s.in_use) ++n;
    }
    return n;
}

int32_t DecoderPool::MaxHardwarePaths() const {
    std::lock_guard<std::mutex> lk(mtx_);
    return max_hardware_paths_;
}

void DecoderPool::SetMaxHardwarePaths(int32_t n) {
    std::lock_guard<std::mutex> lk(mtx_);
    if (n > 0) max_hardware_paths_ = n;
}

std::unique_ptr<IDecoderPool> CreateDecoderPool(
    int32_t max_hardware_paths, std::unique_ptr<IDecoderFactory> factory) {
    return std::unique_ptr<IDecoderPool>(
        new DecoderPool(max_hardware_paths, std::move(factory)));
}

}  // namespace cq
