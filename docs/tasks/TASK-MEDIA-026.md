# TASK-MEDIA-026：导入提速（关键帧扫描懒加载）+ 播放 ~5s 停顿定位（慢调用警报）

> **状态：实现完成，本机全绿；真机复测待描述文件重签（免费证书 7 天过期，2026-10-06）。** 来源：用户真机反馈①「相册导入只是拷贝到本地，
> 耗时有点长」②「导入的视频只能播放五秒就卡帧」。

```yaml
id:          TASK-MEDIA-026
layer:       SDK
goal:        导入探测不再付全文件扫描成本；播放 ~5s 停顿的阻塞调用定位到段
input:       [用户反馈、baselines「泵内分段耗时」（rendered/s=0 停顿窗口 = 同一 bug）、pal/apple/media_demux.mm]
output:      [media_demux.mm 懒扫描、ReadPacket/PopFrame/Seek 慢调用警报（Debug）、单测回归]
write_set:   pal/apple/media_demux.mm、pal/apple/media_decode.mm（警报）、
             core/include/cq/media/system_frame_provider.h（警报）、tests/unit/test_media_*.cpp 回归
read_set:    ADR-0017、.ai/modules/{media,pal-apple}.md
deps:        []
acceptance:
  - 探测路径不再触发 ScanKeyframes ✅（probe 改走 demuxer OpenLight——只读容器时长）
  - 既有 probe/导入/顺序播放测试零回归 ✅（pala_decode 150/150、preview 4/4）
  - 真机：导入耗时显著下降（回填 baselines）⏸ 待描述文件重签
  - ~5s 停顿 **根因已定位并修复**：PopFrame 的 `VTDecompressionSessionWaitFor-
    AsynchronousFrames` 在 VT 静默丢帧时**永久阻塞**（成对日志实测 PopFrame #577
    进入后不返回；VT 丢帧永不回调）→ 改 2ms 轮询 + 最老 pending 超 1s 按丢失处理
    （清 pending + kIoNotFound + 重锚定，播放自恢复）✅ 本机全绿，真机复测待重签
verification:
  - ctest --test-dir build -R 'media|pala_decode'
  - tools/ci/run_gate.sh
  - 真机剖面（同 MEDIA-024 流程）
risk:        懒扫描把成本移到首次 Seek（scrub 跳转首跳多 ~1-3s [E]，可接受——后续可
             后台预扫）；Seek 消费 reader 后由 Seek 自己的 RebuildReader 复位，无残留态
parallel:    true
```

## 背景
1. **导入慢**：`cq_media_probe_duration` 走完整 provider 打开；demuxer `Open` 内
   `ScanKeyframes()` 用 AVAssetReader **逐样本拷出整条视频轨**（422MB 4K60 = 数千帧
   全文件读 + 两次 RebuildReader），每次导入都付。而探测只需要容器时长。
2. **播放 ~5s 卡帧**：与 MEDIA-024 遗留的"偶发多秒停顿"同一 bug（本机剖面
   rendered/s=0 窗口恰好出现在播放 4~6s，非偶发）。嫌疑：demux `ReadPacket` 或
   VT `WaitForAsynchronousFrames` 的无界阻塞（stuck render 不进直方图样本）。
   本卡先上**慢调用警报**（>500ms 打印段名+耗时，Debug only）定位，修复另立卡。

## 实现要点
1. **懒扫描**：demuxer `Open` 只建首个 reader（去掉 ScanKeyframes + 第二次
   RebuildReader）；新增 `keyframes_scanned_` 标志，`Seek` 入口 `EnsureKeyframesScanned()`
   （ScanKeyframes 消费 reader，Seek 随后的 RebuildReader(start) 本就复位，无残留态）。
   收益：导入探测 = 毫秒级；从 0 顺序播放不 seek 也不扫；只有跳转付一次。
2. **慢调用警报**（`#ifndef NDEBUG`）：`AppleDemuxer::ReadPacket`、
   `VideoToolboxDecoder::PopFrame`、`SystemFrameProvider::Seek` 三处包计时，
   单次 >500ms 打印 `[SlowCall] <段> <ms>ms`（stderr 无缓冲，P70）。

## 媒体管线六问
1. 线程：懒扫描发生在 Seek 调用线程（泵线程/测试线程），不变。2. 时序：RationalTime
不变。3. 内存：无新增缓存。4. 取消：Seek 的 CancelToken 传入扫描前的语义保持（扫描
本身不可取消——与原 Open 内行为一致）。5. 错误码：不变。6. 一致性：关键帧吸附语义
不变（表内容与时机无关）；golden 像素断言锁定。

## 验收
acceptance 四条全过。

## 回写
baselines 导入耗时数字；pitfalls 新坑；MEDIA-024 遗留项指向本卡警报结果。
