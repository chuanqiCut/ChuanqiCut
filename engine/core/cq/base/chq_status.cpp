// ChuanqiCut — ChqStatus 错误码体系实现（CORE-002）
//
// 仅依赖 C 基础类型，零平台类型、零异常。见同名头文件的设计约束。

#include "cq/base/chq_status.h"

namespace cq {

const char* StatusToString(ChqStatusCode code) {
    switch (code) {
        case ChqStatusCode::kOk:
            return "OK";
        case ChqStatusCode::kIoError:
            return "IoError";
        case ChqStatusCode::kIoNotFound:
            return "IoNotFound";
        case ChqStatusCode::kIoPermission:
            return "IoPermission";
        case ChqStatusCode::kIoTimeout:
            return "IoTimeout";
        case ChqStatusCode::kDecodeError:
            return "DecodeError";
        case ChqStatusCode::kDecodeUnsupported:
            return "DecodeUnsupported";
        case ChqStatusCode::kDecodeNoKeyframe:
            return "DecodeNoKeyframe";
        case ChqStatusCode::kEncodeError:
            return "EncodeError";
        case ChqStatusCode::kEncodeUnsupported:
            return "EncodeUnsupported";
        case ChqStatusCode::kFormatUnsupported:
            return "FormatUnsupported";
        case ChqStatusCode::kResourceExhausted:
            return "ResourceExhausted";
        case ChqStatusCode::kCancelled:
            return "Cancelled";
        case ChqStatusCode::kInvalidArgument:
            return "InvalidArgument";
        case ChqStatusCode::kOverflow:
            return "Overflow";
        case ChqStatusCode::kInternal:
            return "Internal";
        case ChqStatusCode::kAiPlanJsonMalformed:
            return "AiPlanJsonMalformed";
        case ChqStatusCode::kAiPlanSchemaUnknown:
            return "AiPlanSchemaUnknown";
        case ChqStatusCode::kAiPlanFieldMissing:
            return "AiPlanFieldMissing";
        case ChqStatusCode::kAiPlanFieldType:
            return "AiPlanFieldType";
        case ChqStatusCode::kAiPlanFloatTime:
            return "AiPlanFloatTime";
        case ChqStatusCode::kAiPlanTimescaleMismatch:
            return "AiPlanTimescaleMismatch";
        case ChqStatusCode::kAiPlanTimeNonPositive:
            return "AiPlanTimeNonPositive";
        case ChqStatusCode::kAiPlanUnknownOp:
            return "AiPlanUnknownOp";
        case ChqStatusCode::kAiPlanAssetUnknown:
            return "AiPlanAssetUnknown";
        case ChqStatusCode::kAiPlanShotOutOfRange:
            return "AiPlanShotOutOfRange";
        case ChqStatusCode::kAiPlanSourceRange:
            return "AiPlanSourceRange";
        case ChqStatusCode::kAiPlanTimelineOverlap:
            return "AiPlanTimelineOverlap";
        case ChqStatusCode::kAiPlanReorderNotPermutation:
            return "AiPlanReorderNotPermutation";
        case ChqStatusCode::kAiPlanTransitionKindUnknown:
            return "AiPlanTransitionKindUnknown";
        case ChqStatusCode::kUnknown:
            return "Unknown";
    }
    return "Unknown";
}

ChqStatusCategory CategoryOf(ChqStatusCode code) {
    switch (code) {
        case ChqStatusCode::kOk:
            return ChqStatusCategory::kOk;
        case ChqStatusCode::kIoError:
        case ChqStatusCode::kIoNotFound:
        case ChqStatusCode::kIoPermission:
        case ChqStatusCode::kIoTimeout:
            return ChqStatusCategory::kIo;
        case ChqStatusCode::kDecodeError:
        case ChqStatusCode::kDecodeUnsupported:
        case ChqStatusCode::kDecodeNoKeyframe:
            return ChqStatusCategory::kDecode;
        case ChqStatusCode::kEncodeError:
        case ChqStatusCode::kEncodeUnsupported:
            return ChqStatusCategory::kEncode;
        case ChqStatusCode::kFormatUnsupported:
            return ChqStatusCategory::kFormat;
        case ChqStatusCode::kResourceExhausted:
            return ChqStatusCategory::kResource;
        case ChqStatusCode::kCancelled:
            return ChqStatusCategory::kCancelled;
        case ChqStatusCode::kInvalidArgument:
            return ChqStatusCategory::kInvalidArgument;
        case ChqStatusCode::kOverflow:
            return ChqStatusCategory::kNumeric;
        case ChqStatusCode::kInternal:
            return ChqStatusCategory::kInternal;
        case ChqStatusCode::kAiPlanJsonMalformed:
        case ChqStatusCode::kAiPlanSchemaUnknown:
        case ChqStatusCode::kAiPlanFieldMissing:
        case ChqStatusCode::kAiPlanFieldType:
        case ChqStatusCode::kAiPlanFloatTime:
        case ChqStatusCode::kAiPlanTimescaleMismatch:
        case ChqStatusCode::kAiPlanTimeNonPositive:
        case ChqStatusCode::kAiPlanUnknownOp:
        case ChqStatusCode::kAiPlanAssetUnknown:
        case ChqStatusCode::kAiPlanShotOutOfRange:
        case ChqStatusCode::kAiPlanSourceRange:
        case ChqStatusCode::kAiPlanTimelineOverlap:
        case ChqStatusCode::kAiPlanReorderNotPermutation:
        case ChqStatusCode::kAiPlanTransitionKindUnknown:
            return ChqStatusCategory::kAiPlan;
        case ChqStatusCode::kUnknown:
            return ChqStatusCategory::kUnknown;
    }
    return ChqStatusCategory::kUnknown;
}

}  // namespace cq
