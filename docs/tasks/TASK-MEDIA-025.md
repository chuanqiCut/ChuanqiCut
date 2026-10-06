# TASK-MEDIA-025：解码色彩空间管理（HDR→SDR 正确转换）

> **状态：实现完成，真机目视验收待设备解锁（2026-10-06）。** 来源：用户真机反馈「画面颜色不太对，是不是没有按
> 视频的色彩空间渲染」——结构性实锤：全链路（解码/导入/渲染/呈现）**零色彩管理**，
> golden 校验素材是 SDR 彩条所以从未暴露。

```yaml
id:          TASK-MEDIA-025
layer:       SDK
goal:        HDR（BT.2020 + HLG/PQ）素材解码输出正确转换到 BT.709 SDR；SDR 素材行为不变；源/输出色彩标签全链路可见
input:       [用户反馈、SDK 头文件核查（VTPixelTransferProperties.h / CMFormatDescription.h）、RESEARCH-006 §1]
output:      [media_decode.{h,mm} 色彩转换、诊断日志、单测]
write_set:   pal/apple/media_decode.{h,mm}、tests/unit/test_media_decode_apple.cpp、baselines（真机验证记录）
read_set:    .ai/modules/pal-apple.md、ADR-0003、ADR-0010
deps:        []
acceptance:
  - SDR（BT.709）golden 像素断言零回归（行为不变）✅ 门禁 PASS=9/0
  - 真机实拍 HDR 素材：诊断日志显示源标签且已设 VT 目标 709 转换 ⏸ 待设备解锁
  - 真机目视验收：预览颜色与系统相册一致（传哲）⏸ 待设备解锁
  - 单测：HDR 判定纯函数 ✅（HLG/PQ/宽色域/SDR/标签缺失 6 例）
verification:
  - ctest --test-dir build -R pala_decode
  - tools/ci/run_gate.sh
  - 真机：CQ_AUTO_ROUTE=editor + CQ_AUTO_PLAY=1（stderr 显示色彩标签）+ 传哲目视
risk:        VT 对 HLG→709 的内置转换质量未量化 [E]（行业标准做法，先落地再评估）；
             杜比视界 'dvh1' 基底可能走 DV 特殊转换路径，行为待真机确认（诚实日志）；
             若会话拒绝该属性（部分平台），如实日志并保持旧行为（不 fail Open）
parallel:    true   # 线 C 域；与 MEDIA-024（吞吐）不同文件不相交
```

## 背景
全链路无色彩空间管理：`VideoToolboxDecoder` 请求 BGRA 输出时不设任何目标色彩属性，
HDR 素材（iPhone 实拍 = BT.2020 原色域 + HLG/PQ 传递函数，常见杜比视界封装）经 VT
隐式转换/直通后按 sRGB 显示 → 颜色失真（发灰/过饱和/对比度错误）。

## 实现要点
1. `Open` 时从源 `CMFormatDescription` 读色彩标签（`kCMFormatDescriptionExtension_
   ColorPrimaries/TransferFunction/YCbCrMatrix`）。
2. HDR 判定纯函数 `IsHdrColorSource(prim, transfer)`：transfer ∈ {ITU_R_2100_HLG,
   SMPTE_ST_2084_PQ} 或 prim == ITU_R_2020（配合非 709 transfer）。
3. HDR 时对 VT 会话设 `kVTPixelTransferPropertyKey_Destination{ColorPrimaries,
   TransferFunction,YCbCrMatrix}` = ITU_R_709_2 —— 解码+转换一体（VT 内部完成，
   零额外 pass）。SDR 素材不设任何属性（行为不变）。
4. 诊断：`Open 完成` 行带源标签与转换标记；属性被拒时如实日志（不阻塞）。
5. 媒体管线六问：线程不变（Open 同步段）；RationalTime 不变；内存不变；取消不变；
   错误码不变（属性失败不阻塞）；一致性——SDR golden 逐字节不变，HDR 输出由真机
   目视 + 日志标签验证。

## 验收
acceptance 四条全过。

## 回写
baselines 真机记录；pal-apple.md PALA-011 段增补色彩管理；pitfalls 新坑（若有）。
