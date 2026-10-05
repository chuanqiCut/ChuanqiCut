// ChuanqiCut — Swift 绑定：值类型与全局入口（BIND-002）
//
// 本文件只做**薄封装**：不发明业务逻辑，语义一律以 core/include/cq/cq_sdk.h
// 的注释为准（那份注释是契约，本文件是它的 Swift 投影）。
//
// ⚠️ 命名为什么不带 CQ 前缀：C ABI 里已有 `CQSnapshot` / `CQChangeRecord` 等类型，
//    Swift 模块若再定义同名类型，模块内引用就会与导入的 C 类型混淆（要靠
//    `CChuanqiCut.CQSnapshot` 才能区分）。故 Swift 侧一律用无前缀名，
//    与 C 类型天然不冲突，使用时 `ChuanqiCut.Session` / `Snapshot` 也很自然。
//
// 设计约束：
//   - 内核禁用异常，错误一律状态码 → Swift 侧也不 throw，返回 Status。
//   - 不复制内核的状态码枚举（复制必然漂移）→ 复用数值，只补语义访问器。

import CChuanqiCut

// MARK: - 全局入口

public enum ChuanqiCut {

    public struct Version: Equatable, Sendable {
        public let major: Int32
        public let minor: Int32
        public let patch: Int32
    }

    public static var version: Version {
        Version(major: cq_version_major(), minor: cq_version_minor(), patch: cq_version_patch())
    }

    /// **必须在 App 的 UI 线程调用一次**（SwiftUI App 的 `init()` 或
    /// `application(_:didFinishLaunchingWithOptions:)` 里）。
    ///
    /// 内核无法自行得知哪根是主线程；漏掉这步**不会报错**，只会让
    /// 「主线程零阻塞」的守卫静默失效（见 CORE-008）。务必调用。
    public static func markMainThread() {
        cq_mark_main_thread()
    }

    /// 当前线程是否已被标记为主线程。
    public static var isMainThread: Bool {
        cq_is_main_thread() != 0
    }

    /// 运行时查询能力。**不要**用机型名单或编译期宏推断 ——
    /// 同一系统版本下不同芯片的能力也不同（如 ProRes 硬编仅部分芯片支持）。
    ///
    /// 未安装平台后端时一律返回 `.no` —— 安全默认：宁可降级不可用，不可谎报可用。
    public static func queryCapability(_ capability: Capability) -> CapabilityValue {
        CapabilityValue(rawValue: cq_query_capability(capability.rawValue)) ?? .no
    }
}

// MARK: - 状态码

/// 内核状态码。数值与内核 `StatusCode` **同构**（内核已固化数值区间），
/// 不重新定义一套枚举，只提供常用值与语义判断。
public struct Status: RawRepresentable, Equatable, Sendable {
    public let rawValue: Int32

    public init(rawValue: Int32) { self.rawValue = rawValue }

    public static let ok = Status(rawValue: 0)
    /// 通用解码失败（2000）：打不开容器 / 解析不了。
    public static let decodeError = Status(rawValue: 2000)
    /// 取消：**不是错误**（内核语义：独立的停止信号）。
    public static let cancelled = Status(rawValue: 6000)
    /// 队列满 / 资源耗尽 —— 背压信号，调用方应降速或重试（内核不内置重试）。
    public static let resourceExhausted = Status(rawValue: 5000)
    public static let invalidArgument = Status(rawValue: 7000)

    public var isOK: Bool { cq_status_is_ok(rawValue) != 0 }
    public var isError: Bool { cq_status_is_error(rawValue) != 0 }
    public var isCancelled: Bool { cq_status_is_cancelled(rawValue) != 0 }

    /// 人类可读文本（仅用于日志/展示，禁止进入比较逻辑）。
    public var text: String { String(cString: cq_status_to_string(rawValue)) }
}

/// 使 `Result<_, Status>` 可用（MEDIA-022 probeMediaDurationDetailed 的失败分支）。
/// Status 本身是值语义的状态码，作为 Error 抛出/传递无副作用。
extension Status: Swift.Error {}

// MARK: - 快照与变更

/// 会话快照。
///
/// ⚠️ `digest` **当前恒为 0**：模型层（MODEL-001 TimelineModel）尚未接入内核，
/// 状态摘要没有 C 侧注入入口。版本号语义是完整可用的。
public struct Snapshot: Equatable, Sendable {
    public let version: UInt64
    public let digest: UInt64
}

/// 变更记录（UI 可据此增量刷新）。
public struct ChangeRecord: Equatable, Sendable {
    public let version: UInt64
    public let name: String
}

// MARK: - 能力

public enum Capability: Int32, Sendable {
    case hwDecodeH264 = 0
    case hwDecodeHevc
    case hwDecodeAv1
    case hwDecodeProRes
    case hwEncodeH264
    case hwEncodeHevc
    case hwEncodeProRes
    case tenBitPipeline
    case hdrDisplay
    case computeShader
    case floatTexture
    case externalMemoryImport
    case npuInference
    case gpuMetal
    case gpuGLES
    case gpuVulkan
}

public enum CapabilityValue: Int32, Sendable {
    /// 不可用。
    case no = 0
    /// 可用。
    case yes = 1
    /// 降级可用；或**无法确认** —— 内核查不到时不猜，宁可让上层走降级路径。
    case degraded = 2

    public var isAvailable: Bool { self != .no }
}
