# TASK-MEDIA-022：HEVC 解码支持 + 探测失败诚实透传

> **状态：✅ 已实现（2026-10-05，本集成机）。** 来源：用户真机走查报「导入素材报解码失败」。
> 诊断与实施结论见任务卡 §背景/§实现要点（本机 macOS 宿主实测取证；真机回归待传哲）。

```yaml
id:          TASK-MEDIA-022
layer:       SDK
goal:        VideoToolbox 解码器支持 HEVC（iPhone 相册默认格式），导入/预览不再对 HEVC 报 2001；探测失败原因向 UI 诚实透传
input:       [pitfalls 无（既有文档化限制）, .ai/modules/pal-apple.md PALA-011 范围, ADR-0003]
output:      [pal/apple/media_decode.mm HEVC 支持, 绑定层 probe 状态透传, AppEntry 错误文案分级, ctest/共享测试]
write_set:   pal/apple/media_decode.{h,mm}、pal/apple/media_demux.mm（'hev1'/'dvh1'/'dvhe'
             映射 —— 实测 ffmpeg 产出的 HEVC 是 'hev1'，缺映射时 demuxer 报 kUnknown）、
             bindings/swift/Sources/ChuanqiCut/{Timeline.swift,ChuanqiCut.swift}
             （Status: Error 一致性）、
             apps/apple/packages/SharedUI/Sources/SharedUI/{AppEntry.swift,Editor/MediaSheet.swift}、
             tests/unit/test_media_decode_apple.cpp、bindings Tests/ProbeTests.swift(新)、
             SharedUITests/{RepoPath.swift,MediaImportTests.swift}
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

0. **实施中发现的两个追加堵点**（golden 实测）：
   a. demuxer `VideoCodecToCq` 不认 'hev1'（ffmpeg 默认 tag）→ demuxer 报 kUnknown；
   b. VT 解码器按 'hvc1' 注册，'hev1' 格式描述建会话返回 -12906
      kVTUnsupportedDecompressionErr —— 修法：用同一份 hvcC 重建 subtype='hvc1'
      的 CMFormatDescription（码流与参数集相同，差别只在随流参数集允许性）。
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

## 媒体管线六问（cq-media-pipeline，2026-10-05）

1. **线程**：解码调用方线程不变（预览=泵线程、探测=主线程低频）。Open 内 AVAsset
   异步加载沿用既有「信号量收敛 + 有限超时」模式（H.264 路径原样，HEVC 同构）；
   'hvc1' 重建在 Open 同步段一次性完成。音频路径零触碰。
2. **时序**：RationalTime 全程；重建只换格式描述 subtype（'hev1'→'hvc1'），pts/dts
   与重排逻辑 codec 无关；HEVC golden（无 B 帧）与既有 B 帧 H.264 golden 双覆盖。
3. **内存**：无新增缓存/纹理路径；VT 会话生命周期与 H.264 相同；输出仍 8-bit BGRA
   （4K HEVC 单帧峰值与 H.264 同阶）。HDR 10-bit 素材 VT 自动降采样到 BGRA——
   色调映射不在本期（峰值同阶，hypothesis，真机回填）。
4. **取消**：CancelToken 控制流零改动；重建与诊断打印在 Open 的同步段。
5. **错误码**：全程稳定 Status——'hev1' 无 hvcC → 2001；hvc1 重建失败 → 2000
   （osstatus 进日志）；VT 会话拒绝（如杜比视界基底不被接受）→ 2000 + osstatus
   诊断打印。能力查询沿用既有 hwDecodeHevc 位。
6. **一致性**：预览与导出走同一条解码链（变更在链路底层，两端同受益）；同 seek
   同结果由 pala_decode 端到端 4 目标时间断言锁定；iOS/macOS 共用本 PAL 实现。

 Checklist：时序/内存/取消由既有测试模式覆盖（150 帧 pts 单调 + 像素 + drain，
 HEVC 段同断言强度）；golden 像素校验 = pala_decode 的 smptebars 断言；性能未实测
 （解码耗时 hypothesis：与 H.264 同量级，真机回填 baselines）。

## 回写
`.ai/modules/pal-apple.md` PALA-011 段增补 HEVC；`.ai/modules/media.md` 若流信息映射变化。
