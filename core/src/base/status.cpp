// ChuanqiCut — Status 错误码体系实现（CORE-002）
//
// 仅依赖 C 基础类型，零平台类型、零异常。见同名头文件的设计约束。

#include "cq/base/status.h"

namespace cq {

const char* StatusToString(StatusCode code) {
    switch (code) {
        case StatusCode::kOk:                return "OK";
        case StatusCode::kIoError:           return "IoError";
        case StatusCode::kIoNotFound:        return "IoNotFound";
        case StatusCode::kIoPermission:      return "IoPermission";
        case StatusCode::kIoTimeout:         return "IoTimeout";
        case StatusCode::kDecodeError:       return "DecodeError";
        case StatusCode::kDecodeUnsupported: return "DecodeUnsupported";
        case StatusCode::kDecodeNoKeyframe:  return "DecodeNoKeyframe";
        case StatusCode::kEncodeError:       return "EncodeError";
        case StatusCode::kEncodeUnsupported: return "EncodeUnsupported";
        case StatusCode::kFormatUnsupported: return "FormatUnsupported";
        case StatusCode::kResourceExhausted: return "ResourceExhausted";
        case StatusCode::kCancelled:         return "Cancelled";
        case StatusCode::kInvalidArgument:   return "InvalidArgument";
        case StatusCode::kOverflow:          return "Overflow";
        case StatusCode::kInternal:          return "Internal";
        case StatusCode::kUnknown:           return "Unknown";
    }
    return "Unknown";
}

StatusCategory CategoryOf(StatusCode code) {
    switch (code) {
        case StatusCode::kOk:                return StatusCategory::kOk;
        case StatusCode::kIoError:
        case StatusCode::kIoNotFound:
        case StatusCode::kIoPermission:
        case StatusCode::kIoTimeout:         return StatusCategory::kIo;
        case StatusCode::kDecodeError:
        case StatusCode::kDecodeUnsupported:
        case StatusCode::kDecodeNoKeyframe:  return StatusCategory::kDecode;
        case StatusCode::kEncodeError:
        case StatusCode::kEncodeUnsupported: return StatusCategory::kEncode;
        case StatusCode::kFormatUnsupported: return StatusCategory::kFormat;
        case StatusCode::kResourceExhausted: return StatusCategory::kResource;
        case StatusCode::kCancelled:         return StatusCategory::kCancelled;
        case StatusCode::kInvalidArgument:   return StatusCategory::kInvalidArgument;
        case StatusCode::kOverflow:          return StatusCategory::kNumeric;
        case StatusCode::kInternal:          return StatusCategory::kInternal;
        case StatusCode::kUnknown:           return StatusCategory::kUnknown;
    }
    return StatusCategory::kUnknown;
}

}  // namespace cq
