// ChuanqiCut — FeatureReport 契约（AIEDIT-001，schema cq.featurereport/1）
//
// 本地特征聚合报告：上云的只有这一份 JSON + 用户消息（ADR-0020 决策 1，
// 「素材不出设备」承诺的技术基础——特征全部为聚合统计，不含帧图像、
// 不含可逆还原素材的信息；人脸只报 count/area_ratio/front_facing，不做识别）。
//
// JSON 形状（SPEC AIEDIT-001 §4，schema v1 冻结；扩展位 extensions 兜底后续字段）：
// {
//   "schema": "cq.featurereport/1",
//   "project": { "timescale": 120000 },
//   "assets": [{
//     "asset_id": "a1",
//     "duration": {"value": 60000, "timescale": 120000},
//     "fps": {"num": 30, "den": 1},
//     "resolution": {"width": 1920, "height": 1080},
//     "video": {
//       "shots": [{"start": {...}, "duration": {...}, "motion": 0.72, "quality": 0.81,
//                  "faces": {"count": 2, "area_ratio": 0.18, "front_facing": true}}],
//       "brightness_trend": [-0.1, 0.3],
//       "dominant_colors": ["#3A5F8A"]
//     },
//     "audio": { "lufs": -18.5, "silences": [...], "speech_ratio": 0.6,
//                "energy_envelope": [...] }
//   }],
//   "cross": { "quality_rank": ["a2","a1"], "duplicate_shots": [["a1:0","a3:2"]],
//              "highlight_candidates": ["a2:1","a1:3"] },
//   "extensions": {}
// }
//
// 时间语义（红线 4）：本文件的时间字段一律 RationalTime（JSON 投影为
// {"value","timescale"}），禁止浮点秒；fps 为独立有理数 {"num","den"}。
// motion/quality/lufs/speech_ratio 等是**统计标量**，允许浮点（红线 4 只约束时间）。
//
// 序列化/解析的落点：产出方 AIEDIT-002（视觉）/AIEDIT-003（音频）负责序列化，
// 消费方 AIEDIT-005（Prompt 管线）负责解析——本卡只冻结类型与 JSON 形状。
// 素材类型枚举（video/still/animated/livephoto）归 LIB-001（素材库契约），不在此预占。

#ifndef CQ_AI_FEATURE_REPORT_H_
#define CQ_AI_FEATURE_REPORT_H_

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

#include "cq/base/rational_time.h"

namespace cq {

// FeatureReport schema 版本标识（JSON "schema" 字段值）。
constexpr const char* kFeatureReportSchema = "cq.featurereport/1";

// 人脸占位特征（检测计数级信息，非识别；P0 模型缺席时 has_faces=false）。
struct FeatureFace {
    int32_t count = 0;
    double area_ratio = 0.0;    // 0~1，人脸像素占比
    bool front_facing = false;
};

// 镜头段（场景切分产物）。
struct FeatureShot {
    RationalTime start{};
    RationalTime duration{};
    double motion = 0.0;        // 0~1 运动强度（帧差均值）
    double quality = 0.0;       // 0~1 综合质量（曝光/模糊/噪声加权）
    bool has_faces = false;     // false = 人脸特征缺席（JSON 里 faces 为 null）
    FeatureFace faces{};
};

struct FeatureVideo {
    std::vector<FeatureShot> shots;
    bool has_brightness_trend = false;  // 调性粗特征，可选
    std::vector<double> brightness_trend;
    std::vector<std::string> dominant_colors;   // 最多 3 个（"#RRGGBB"）
};

struct FeatureSilence {
    RationalTime start{};
    RationalTime duration{};
};

// 音频特征（AIEDIT-003 解码扩档落地前整块缺席：has_* 全 false，JSON 里 audio=null）。
struct FeatureAudio {
    bool has_lufs = false;
    double lufs = 0.0;          // 综合响度（BS.1770 简化实现）
    std::vector<FeatureSilence> silences;
    bool has_speech_ratio = false;
    double speech_ratio = 0.0;  // VAD 粗判 0~1
    std::vector<double> energy_envelope;    // ~10Hz 均方根包络（卡点用）
};

struct FeatureFps {
    int32_t num = 0;
    int32_t den = 1;
};

struct FeatureResolution {
    int32_t width = 0;
    int32_t height = 0;
};

struct FeatureAsset {
    std::string asset_id;
    RationalTime duration{};
    FeatureFps fps{};
    FeatureResolution resolution{};
    bool has_video = false;     // 纯音频素材 video 缺席
    FeatureVideo video{};
    bool has_audio = false;     // AIEDIT-003 之前为 false
    FeatureAudio audio{};
};

// 跨素材分析。
struct FeatureCross {
    std::vector<std::string> quality_rank;  // 按质量降序的 asset_id
    // 疑似重复镜头组，元素形如 "a1:0"（asset_id:shot 序号）。
    std::vector<std::pair<std::string, std::string>> duplicate_shots;
    std::vector<std::string> highlight_candidates;  // 质量×运动×人脸加权
};

// FeatureReport 顶层（schema v1）。
struct FeatureReport {
    std::string schema = kFeatureReportSchema;
    int32_t project_timescale = kProjectTimeScale;  // {"project":{"timescale":...}}
    std::vector<FeatureAsset> assets;
    FeatureCross cross{};
    // 版本化扩展位：未知字段原样保留（宽松解析，不猜测语义），原始 JSON 文本。
    std::string extensions_raw;
};

}  // namespace cq

#endif  // CQ_AI_FEATURE_REPORT_H_
