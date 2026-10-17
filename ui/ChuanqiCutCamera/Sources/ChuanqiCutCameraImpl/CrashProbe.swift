// CrashProbe — 真机 SIGTRAP/SIGABRT 取证（CAM-033 美颜闪/崩定位批，2026-10-11）
//
// 背景：美颜开启（探针 CQ_CAM_BEAUTY）必现 signal 5，Swift fatal 消息走 os_log
// 异步流不进 devicectl console（stderr 只有 fputs 的手写行），crash report 又延迟
// 落盘 —— 装 POSIX signal handler 把崩溃现场的 backtrace 帧地址直接打 stderr，
// 拿 ASLR slide（App load address）手工减去即得符号地址，nm/atos 定位。
//
// 只在 CQ_CAM_FACE_CALIB=1（探针/取证模式）安装；正常构建零影响。

import Darwin
import Foundation

enum CrashProbe {

    /// App 主二进制加载基址（ASLR slide 后）——帧地址 - 基址 = 文件内偏移，
    /// 与 `atos -o ChuanqiCutApp.debug.dylib -l <基址>` 或 nm 符号表对照。
    static func install() {
        // C 函数指针只能由非捕获闭包字面量构成 → 闭包内调 static 方法（无捕获）。
        signal(SIGTRAP) { CrashProbe.trap($0) }
        signal(SIGABRT) { CrashProbe.trap($0) }
        signal(SIGILL) { CrashProbe.trap($0) }
        signal(SIGSEGV) { CrashProbe.trap($0) }
        signal(SIGBUS) { CrashProbe.trap($0) }
        fputs("[crash-probe] signal handlers installed\n", stderr)
        fflush(stderr)
    }

    /// 主动打调用栈（定位"谁调了我"——configureAndStart 二次触发取证用）。
    static func traceNow(_ tag: String) {
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let n = backtrace(&frames, 64)
        let count = max(Int(n), 0)
        let addrs = Array(frames.prefix(count))
        let syms = addrs.withUnsafeBufferPointer { buf -> UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>? in
            backtrace_symbols(buf.baseAddress, Int32(count))
        }
        fputs("[crash-probe] trace[\(tag)] (\(count) frames):\n", stderr)
        if let syms {
            for i in 1..<count {   // 跳过 traceNow 自身帧
                let cstr = syms[i]
                let text = cstr.map { String(cString: $0) } ?? "(null)"
                fputs("[crash-probe]   #\(i) \(text)\n", stderr)
            }
        }
        fflush(stderr)
    }

    private static func trap(_ signo: Int32) {
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let n = backtrace(&frames, 64)
        let count = max(Int(n), 0)
        let addrs = Array(frames.prefix(count))   // [UnsafeMutableRawPointer?]（backtrace_symbols 的入参类型）
        fputs("\n[crash-probe] !!! signal \(signo) backtrace (\(count) frames):\n", stderr)
        let syms = addrs.withUnsafeBufferPointer { buf -> UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>? in
            backtrace_symbols(buf.baseAddress, Int32(count))
        }
        if let syms {
            for i in 0..<count {
                let cstr = syms[i]  // optional：backtrace_symbols 对外部帧可能给 null
                fputs("[crash-probe]   #\(i) \(cstr.map { String(cString: $0) } ?? "(null)")\n", stderr)
            }
        }
        var info = Dl_info()
        if count > 2, let addr = addrs[2], dladdr(addr, &info) != 0 {
            fputs("[crash-probe]   dli_fbase=\(info.dli_fbase) (\(info.dli_fname))\n", stderr)
        }
        fflush(stderr)
        // 恢复默认处理，让系统正常落 crash report
        signal(signo, SIG_DFL)
        raise(signo)
    }
}
