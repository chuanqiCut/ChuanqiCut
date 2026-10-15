// DebugCrashDumper — 真机崩溃取证通道（DEBUG only）
//
// 由来：2026-10-14 排查「进编辑页必现 signal 11」时发现两条外部通道都拿不到栈：
//   ① `xcrun devicectl device process launch` 启动的进程崩溃**不落 CrashReporter .ips**
//      （`device copy from --domain-type systemCrashLogs` 反复拉取都没有新日志）；
//   ② `lldb` 的 `device process attach -p <pid>` 能挂上（`process status` 报 running），
//      但后续 `continue` / `thread list` 一律 `Process must be launched` —— 拿不到
//      可用的 Process 对象，无法取回溯。
// 故留这条进程内自取通道：崩溃信号到来时把 `Thread.callStackSymbols` 打到 **stderr**
// （stdout 全缓冲会丢日志，项目既有探针已踩过 —— 见 AppEntry 的 fputs 注释）。
//
// ⚠️ 信号处理里做 Swift 字符串/数组操作并非 async-signal-safe，代价是偶发二次崩溃；
//    取舍理由：进程反正要死，最想要的是那一份栈。Release 不编译（DEBUG only）。
//
// 用法：`xcrun devicectl device process launch --console ... com.chuanqi.cut`，
//      崩溃瞬间 stderr 会出现 `[crash] signal=...` + 回溯若干行。

#if DEBUG
import Foundation
import Darwin

enum DebugCrashDumper {

    /// 只由 `ChuanqiCutApp.init` 调一次，故不做可重入守卫（Swift 6 下静态可变
    /// 状态要标 nonisolated(unsafe)，不如不持有状态）。
    static func install() {
        var action = sigaction()
        action.__sigaction_u.__sa_sigaction = { sig, _, _ in
            fputs("\n[crash] signal=\(sig) —— 回溯如下\n", stderr)
            for line in Thread.callStackSymbols {
                fputs(line + "\n", stderr)
            }
            fflush(stderr)
            // 交还给默认行为（让 devicectl 仍能报 "terminated due to signal"）。
            signal(sig, SIG_DFL)
            raise(sig)
        }
        sigemptyset(&action.sa_mask)
        action.sa_flags = SA_SIGINFO
        for s in [SIGSEGV, SIGBUS, SIGABRT] as [Int32] {
            sigaction(s, &action, nil)
        }
        fputs("[probe] DebugCrashDumper 已安装（SIGSEGV/SIGBUS/SIGABRT → stderr）\n", stderr)
        fflush(stderr)
    }
}
#endif
