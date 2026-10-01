// SharedUI — App 入口支撑：EditorViewModel（UIA-002）
//
// 架构铁律（ARCH-005 §3）：UI 不得直接改模型 —— 一切变更走 `submit()`（Command），
// 状态通过快照 observer 回流。本类是 UI 与内核会话之间的唯一通道。
//
// 线程模型：
//   - 本类 @MainActor：所有 @Published 状态只在主线程读写。
//   - 内核在 session 线程执行 mutate、回调 observer；绑定层已把 observer
//     转发到 main queue，但 Swift 6 并发模型不认识 "main queue == MainActor"，
//     故这里再用 `Task { @MainActor }` 跳一次（见 Session.swift 注释）。
//   - `submit()` 非阻塞（内核投递到 session 线程后立刻返回），主线程零阻塞。

import SwiftUI
import ChuanqiCut

// MARK: - 错误

public enum EditorError: Error, Sendable {
    /// 内核会话创建失败（静态库未链接 / session 线程启动失败）。
    case sessionCreationFailed
}

// MARK: - 视图模型

@MainActor
public final class EditorViewModel: ObservableObject {

    // MARK: 状态（UI 只读）

    /// 当前内核快照。版本号单调递增；digest 在 MODEL-001 落地前恒为 0。
    @Published public private(set) var snapshot: Snapshot

    /// 最近一次快照推进所包含的变更记录（UI 可据此增量刷新）。
    @Published public private(set) var lastChanges: [ChangeRecord] = []

    /// 内核能力（预览区 / 导出 UI 可据此决定降级展示）。
    @Published public private(set) var capabilities: [Capability: CapabilityValue] = [:]

    // MARK: 内核会话

    private let session: Session
    private var knownVersion: UInt64

    public init() throws {
        guard let session = Session() else {
            throw EditorError.sessionCreationFailed
        }
        self.session = session
        self.snapshot = session.currentSnapshot
        self.knownVersion = session.currentSnapshot.version

        // 订阅快照变更：内核 session 线程 → 绑定层 main queue → 本处 MainActor。
        session.setSnapshotObserver { [weak self] snap in
            Task { @MainActor [weak self] in
                self?.applySnapshot(snap)
            }
        }
    }

    // MARK: 命令提交（UI → 内核的唯一写入口）

    /// 提交一次变更。不阻塞调用线程。
    ///
    /// - Parameter changeName: **字符串字面量**（内核只存指针不拷贝）。
    @discardableResult
    public func submit(_ changeName: StaticString, mutate: @escaping () -> Status) -> Status {
        session.submit(changeName, mutate: mutate)
    }

    /// 查询内核能力并缓存到 `capabilities`（App 启动时调用一次）。
    public func refreshCapabilities() {
        var result: [Capability: CapabilityValue] = [:]
        for capability in allCapabilities {
            result[capability] = ChuanqiCut.queryCapability(capability)
        }
        capabilities = result
    }

    // MARK: 快照回流

    private func applySnapshot(_ snap: Snapshot) {
        guard snap.version != knownVersion else { return }
        lastChanges = session.changesSince(knownVersion)
        knownVersion = snap.version
        snapshot = snap
    }
}

/// 能力全集（Capability 是从 0 起连续编号的 enum）。
private var allCapabilities: [Capability] {
    [
        .hwDecodeH264, .hwDecodeHevc, .hwDecodeAv1, .hwDecodeProRes,
        .hwEncodeH264, .hwEncodeHevc, .hwEncodeProRes,
        .tenBitPipeline, .hdrDisplay, .computeShader, .floatTexture,
        .externalMemoryImport, .npuInference,
        .gpuMetal, .gpuGLES, .gpuVulkan,
    ]
}
