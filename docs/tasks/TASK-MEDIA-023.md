# TASK-MEDIA-023：VT 解码输出降采样 ≤1080p（预览吞吐修复）

> **状态：实现完成，真机复测待设备（2026-10-06）。** 关键事实：降采样已生效
> （2160x3840→1080x1920）但泵吞吐仍 13~23 帧/s —— **「BGRA 转换带宽」假设被证伪**，
> 瓶颈更深（VT 逐帧提交→回调串行往返 or 10-bit HDR→SDR 转换慢路径）。已内置
> Feed→回调延迟直方图（Debug only）与 hw 标志打印，设备接回即一键复测定案。

```yaml
id:          TASK-MEDIA-023
layer:       SDK
goal:        VideoToolbox 解码输出尺寸上限 1080p（VT 内部解码+缩放一体），把单帧取帧耗时压进帧间隔，播放达到素材满帧
input:       [baselines「预览播放吞吐」、RESEARCH-006 §1 #4、ADR-0017]
output:      [media_decode.mm 输出属性、pala_decode 降采样断言]
write_set:   pal/apple/media_decode.{h,mm}、tests/unit/test_media_decode_apple.cpp、
             .ai/memory/baselines.md（真机复测回填）
read_set:    .ai/modules/{pal-apple,media}.md、VT 文档（kVTDecompressionPropertyKey_OutputWidth/Height）
deps:        []
acceptance:
  - 4K 素材解码输出 CVPixelBuffer ≤ 1920×1080（保持宽高比，偶数对齐）✅ 钳制纯函数断言
  - 1080p 及以下素材输出尺寸不变（逐字节行为兼容）✅ golden 1080p 全绿
  - pala_decode 双 codec 断言全绿（含新降采样断言）✅ 门禁 PASS=9/0
  - 真机复测 pump_rendered/s ≥ 55 ⏸ 待设备解锁（仪器已装包：VT 单帧延迟
    p50 8-10ms / p95 12ms——解码本身很快；泵内 acquire/import/draw 分段直方图
    待采集定案下一步修法）
verification:
  - ctest --test-dir build -R pala_decode
  - tools/ci/run_gate.sh
  - 真机：CQ_AUTO_PLAY=1 剖面（同阶段 0 流程）
risk:        降采样质量（线性 vs 高质量插值）由 VT 决定，预览可接受 [E]；导出链路（未落地）
             未来若需原始分辨率，届时按用途拆会话（RENDER-001 后另有归口）
parallel:    true
```

## 背景
真机剖面（baselines）：60fps 实拍素材播放时泵只出 17~32 帧/秒。hypothesis 主嫌 =
4K 源帧 NV12→BGRA 转换写带宽（33MB/帧）；VT 输出降采样后每帧 ≤6MB，转换/导入/blit
全链路同步受益。

## 实现要点
- `VTDecompressionSessionCreate` 前设 `kVTDecompressionPropertyKey_OutputWidth/Height`
  （上限 1080p，等比缩，宽高取偶）；`OutputDimensions` 记录实际输出尺寸供诊断。
- 只动 PAL 解码器；调用方（preview 泵链路）零改动。现阶段全链路皆预览（导出未落地），
  无"需要原始分辨率"的消费方；RENDER-001 后若导出需要，另拆会话。

## 媒体管线六问
1. 线程：Open 同步段设置属性，不变。2. 时序：RationalTime 不变。3. 内存：输出帧
   33MB→≤6MB，净降。4. 取消：不变。5. 错误码：属性设置失败如实 kDecodeError（带
   osstatus 打印）。6. 一致性：像素断言改在降采样后尺寸上做（smptebars 主序不变）。
