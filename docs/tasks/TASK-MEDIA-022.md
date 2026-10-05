# TASK-MEDIA-022：HEVC 解码支持 + 探测失败诚实透传

> **状态：待开工（2026-10-05 立项）。** 来源：用户真机走查报「导入素材报解码失败」。
> 诊断结论见任务卡 §背景（已实测取证，本机 macOS 宿主复现）。

```yaml
id:          TASK-MEDIA-022
layer:       SDK
goal:        VideoToolbox 解码器支持 HEVC（iPhone 相册默认格式），导入/预览不再对 HEVC 报 2001；探测失败原因向 UI 诚实透传
input:       [pitfalls 无（既有文档化限制）, .ai/modules/pal-apple.md PALA-011 范围, ADR-0003]
output:      [pal/apple/media_decode.mm HEVC 支持, 绑定层 probe 状态透传, AppEntry 错误文案分级, ctest/共享测试]
write_set:   pal/apple/media_decode.{h,mm}、core/src/media/media_probe_abi.cpp（如需透传码）、
             bindings/swift/Sources/ChuanqiCut/{Timeline.swift,ChuanqiCut.swift}、
             apps/apple/packages/SharedUI/Sources/SharedUI/AppEntry.swift、
             tests/unit/test_media_*（相应扩展）
read_set:    .ai/modules/{media,pal-apple,preview}.md、ADR-0003、ADR-0010、ADR-0017
deps:        []
acceptance:
  - cq_media_probe_duration 对 gf_1080p_hevc.mp4 返回 0（当前实测 2001 kDecodeUnsupported）
  - HEVC golden 帧渲染像素断言通过（VT 解码 → BGRA → 零拷贝链路全通）
  - probe 失败时 UI 文案区分「格式不支持(2001)/文件无法解析(1000)/解码失败(2000)」
  - H.264 既有 golden 全部零回归；总门禁全绿
verification:
  - ctest --test-dir build -R media
  - cd bindings/swift && swift test --disable-sandbox
  - cd apps/apple/packages/SharedUI && swift test --disable-sandbox
  - tools/ci/run_gate.sh
risk:        10-bit HDR → BGRA 输出转换的色彩/范围问题（VT 自动转换需像素断言锁定）；Dolby Vision
             素材 codec type 为 'dvh1'/'dvhe'，需确认 VT 会话对 DV 格式描述的接受度（不接受则
             如实报 2001，不伪造）；ProRes/MJPEG 同理仍不支持
parallel:    true   # 线 C 域；与线 A SharedUI 错误文案小改解耦（绑定层透传归本卡）
```

## 背景（2026-10-05 诊断，已实测）

用户真机导入相册素材报「解码失败」。证据链：

1. iPhone 相册默认录制 **HEVC**（"高效"格式；Dolby Vision 亦为 HEVC 系容器）。
2. 导入流程第一步 `probeMediaDuration` 实际打开**完整解码管线**（demuxer + 解码器），
   而 `VideoToolboxDecoder::Open`（`pal/apple/media_decode.mm` 143/194 行）**只接受
   H.264**：`bound_codec_ != kH264` / `codec != kCMVideoCodecType_H264` →
   `kDecodeUnsupported (2001)`。HEVC 时长探测从未成功过 —— 该限制是
   PALA-011 的文档化已知范围（`.ai/modules/pal-apple.md`「后续任务」）。
3. 绑定层 `probeMediaDuration` 把一切非 0 码折叠成 nil，`importMedia` 再折叠成
   `.decodeError` → UI 统一显示「解码失败」，掩盖了「格式不支持」。
4. 实测（本机 macOS 宿主，bindings swift test 注入，2026-10-05）：
   `gf_1080p_h264.mp4 → code=0 (600000/120000)`；`gf_1080p_hevc.mp4 → code=2001`。

## 实现要点

1. `VideoToolboxDecoder::Open`：接受 `CodecId::kHevc` + `kCMVideoCodecType_HEVC`
   （'hvc1'/'hev1'）；Dolby Vision（'dvh1'/'dvhe'）尝试按 HEVC 建 VT 会话，失败如实
   2001；format desc 取自 track.formatDescriptions（hvcC），Feed 路径不变（AVAssetReader
   passthrough 的长度前缀 NALU + hvcC 与 AVCC 同构）。输出仍 32BGRA（VT 自动
   10→8 位转换，像素断言锁定色彩正确性）。
2. probe 透传：`cq_media_probe_duration` 已原样返回底层码；绑定层新增
   `probeMediaDurationDetailed(path) -> Result<RationalTime, Status>`（旧 API 保留），
   `AppEntry.importMedia` 据此把 2001 显示为「格式暂不支持（HEVC 等）」。
3. 守卫：新增 HEVC probe/渲染单测（golden 素材已有 `gf_1080p_hevc.mp4`）。
4. **媒体管线六问**（cq-media-pipeline）：解码路径变更 —— 线程归属不变（泵线程）、
   RationalTime 不变、VT 会话内存语义不变、取消语义不变、错误码新增 HEVC 成功路径、
   同 seek 结果一致性由像素断言锁定。

## 验收
acceptance 四条全过。

## 回写
`.ai/modules/pal-apple.md` PALA-011 段增补 HEVC；`.ai/modules/media.md` 若流信息映射变化。
