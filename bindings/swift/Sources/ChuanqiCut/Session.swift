// ChuanqiCut — Swift 绑定：EditorSession 门面（BIND-002）
//
// 对应内核 CQSession（core/src/session/editor_session.h + cq_sdk.h）。
//
// 三条容易踩的坑，这里都显式处理了：
//
// 1. **C 函数指针不能捕获上下文**。CQMutateFn / CQSnapshotObserver 都是
//    `@convention(c)`，Swift 闭包一旦捕获变量就转不了。故一律用
//    「函数指针 + void* 上下文」把 Swift 盒子传进去再取回来。
//
// 2. **观察者回调不在主线程**。内核在 **session 线程**回调（见 cq_sdk.h 注释），
//    直接更新 UI 就是灾难。故这里默认 dispatch 到 `DispatchQueue.main`，
//    并允许调用方指定队列。
//
// 3. **changeName 必须是字符串字面量**。内核只保存指针、不拷贝，
//    故参数类型是 `StaticString`（其 utf8Start 指向静态存储且 NUL 结尾），
//    用 String 会导致悬垂指针 —— 这是刻意的 API 限制，不是笔误。

import CChuanqiCut
import Foundation

public final class Session {

    // MARK: 生命周期

    // internal（非 private）：Timeline.swift 等同模块扩展文件要访问 C 句柄。
    // 对外仍不可见（模块外 private 语义等效，Swift 无「文件外 module 内」粒度）。
    var handle: OpaquePointer?

    /// 创建并启动会话。内核启动失败时返回 nil。
    public init?() {
        guard let h = cq_session_create() else { return nil }
        handle = h
    }

    deinit {
        guard let h = handle else { return }
        // 先摘掉观察者再销毁：否则销毁后仍有回调打进来就是悬垂指针。
        cq_session_set_observer(h, nil, nil)
        observerBox = nil
        cq_session_destroy(h)
        handle = nil
    }

    // MARK: 变更提交

    /// 提交一次变更。**不阻塞调用线程**（内核投递到 session 线程后立刻返回）。
    ///
    /// - Parameters:
    ///   - changeName: **字符串字面量**（StaticString）。内核只存指针不拷贝。
    ///   - mutate: 在 **session 线程** 执行的变更体；返回 `.ok` 才会推进快照版本。
    /// - Returns:
    ///   - `.ok` 已入队
    ///   - `.resourceExhausted` 队列满（背压）—— 调用方应降速或重试，内核不内置重试
    ///   - `.invalidArgument` 会话已失效
    ///
    /// ⚠️ 已知限制：若会话在任务执行前被销毁，`mutate` 闭包所占的盒子不会被释放
    /// （内核不会再回调）。量级受队列容量限制（默认 64），当前可接受；
    /// 需要严格零泄漏时应改用「Session 持有未完成任务注册表」的方案。
    @discardableResult
    public func submit(_ changeName: StaticString, mutate: @escaping () -> Status) -> Status {
        guard let h = handle else { return .invalidArgument }

        let box = MutateBox(mutate)
        let ctx = Unmanaged.passRetained(box).toOpaque()

        let code = changeName.withUTF8Buffer { buf -> Int32 in
            guard let base = buf.baseAddress else { return Status.invalidArgument.rawValue }
            return base.withMemoryRebound(to: CChar.self, capacity: buf.count) { namePtr in
                cq_session_submit(h, namePtr, { rawCtx in
                    guard let rawCtx else { return Status.invalidArgument.rawValue }
                    let box = Unmanaged<MutateBox>.fromOpaque(rawCtx).takeRetainedValue()
                    return box.fn().rawValue
                }, ctx)
            }
        }

        // 入队失败：内核不会回调，盒子得自己放掉，否则泄漏。
        if code != Status.ok.rawValue {
            Unmanaged<MutateBox>.fromOpaque(ctx).release()
        }
        return Status(rawValue: code)
    }

    // MARK: 快照与变更日志

    public var currentSnapshot: Snapshot {
        guard let h = handle else { return Snapshot(version: 0, digest: 0) }
        let s = cq_session_current_snapshot(h)
        return Snapshot(version: s.version, digest: s.digest)
    }

    /// 取 `fromVersion` 之后发生的全部变更（UI 可据此增量刷新）。
    public func changesSince(_ fromVersion: UInt64) -> [ChangeRecord] {
        guard let h = handle else { return [] }
        var buffer = [CChuanqiCut.CQChangeRecord](repeating: CQChangeRecord(), count: 64)
        let n = cq_session_changes_since(h, fromVersion, &buffer, Int32(buffer.count))
        guard n > 0 else { return [] }
        return (0..<Int(n)).map { i in
            ChangeRecord(version: buffer[i].version,
                         name: buffer[i].name.map { String(cString: $0) } ?? "")
        }
    }

    public var changeCount: Int {
        guard let h = handle else { return 0 }
        return Int(cq_session_change_count(h))
    }

    // MARK: 观察者

    private var observerBox: ObserverBox?

    /// 订阅快照变更。
    ///
    /// ⚠️ 内核在 **session 线程** 回调；这里默认转发到 `DispatchQueue.main`。
    /// 若传了自定义 queue，请自行保证它适合做 UI 更新。
    ///
    /// 传 nil 取消订阅。Session 销毁时会自动摘除观察者。
    public func setSnapshotObserver(queue: DispatchQueue = .main,
                                    _ handler: (@Sendable (Snapshot) -> Void)?) {
        guard let h = handle else { return }
        guard let handler else {
            cq_session_set_observer(h, nil, nil)
            observerBox = nil
            return
        }

        let box = ObserverBox(handler: handler, queue: queue)
        observerBox = box  // Session 持有，回调侧用 passUnretained
        let ctx = Unmanaged.passUnretained(box).toOpaque()

        cq_session_set_observer(h, { cSnap, rawCtx in
            guard let rawCtx else { return }
            let box = Unmanaged<ObserverBox>.fromOpaque(rawCtx).takeUnretainedValue()
            let snap = Snapshot(version: cSnap.version, digest: cSnap.digest)
            box.queue.async { box.handler(snap) }
        }, ctx)
    }
}

// MARK: - 内部：C 回调的上下文盒子

/// 变更体盒子。生命周期由 Unmanaged 的 retain/release 管理（见 submit 注释）。
private final class MutateBox {
    let fn: () -> Status
    init(_ fn: @escaping () -> Status) { self.fn = fn }
}

/// 观察者盒子。由 Session 强引用持有（观察者会被多次调用，不能 takeRetainedValue）。
///
/// `@unchecked Sendable`：本类的字段全是不可变 `let`，创建后只读，跨线程传递安全。
/// 加这个标记是为了消掉 Swift 6 并发检查的告警 —— 按项目纪律，告警要改代码消除，
/// 不用 `-Wno-*` 之类的逃逸开关。
private final class ObserverBox: @unchecked Sendable {
    let handler: @Sendable (Snapshot) -> Void
    let queue: DispatchQueue
    init(handler: @escaping @Sendable (Snapshot) -> Void, queue: DispatchQueue) {
        self.handler = handler
        self.queue = queue
    }
}
