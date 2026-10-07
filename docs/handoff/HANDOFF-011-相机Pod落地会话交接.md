# HANDOFF-011：相机 Pod 落地（阶段 4 提前）+ 壳工程三个假绿案底（会话交接）

> 2026-10-07 深夜二轮。传哲指出「拍摄怎么还在工程」→ [INFRA-018](../tasks/TASK-INFRA-018.md)
> 从 PLAN 顺序中**提前执行完毕**：ChuanqiCutCamera 成为独立 iOS Pod。另含 P84（.build
> 入库）与 P85（迁移假绿三连）两条新规则。阶段 0/1 见 HANDOFF-010。

## 当前 Pod 拓扑（实况）

| Pod | 状态 | 平台 | 依赖 |
|---|---|---|---|
| ChuanqiCut（SDK） | 不动 | 双端 | — |
| SharedUI（基座） | 已迁出 Player+Camera，剩 AppEntry/Common/Editor/MediaPicker/Timeline | 双端 | SDK |
| ChuanqiCutPlayer | ✅ 阶段 1（52 测试） | 双端 | 无（实测零符号） |
| **ChuanqiCutCamera** | ✅ **阶段 4 提前**（36 契约测试） | **仅 iOS** | SharedUI（EditorEntryInjector） |
| Import / Assets / Editor+Draft | ⏳ 阶段 2/3/5 | | |

测试守恒链：HEAD 140 = SharedUI 52 + Player 52 + Camera 36。

## 本轮新规则/案底（读 pitfalls P84、P85）

- **P84 构建产物零入库**：gitignore 通配 + 门禁 artifacts 步（PASS 基线 **11**）+ SPM
  产物统一 `--scratch-path "$ROOT/build/spm/<包名>"`。
- **P85 迁移假绿三连**：①`.metal` 绝不进 podspec source_files（Xcode 内建 Metal 阶段会
  编它 → air-lld 未解析 coreimage:: 符号）；②静态库 Pod script_phase 产物**到不了
  App bundle**（Copy Pods Resources 只拷 install 期声明资源）且未声明 inputs/outputs
  会被增量构建跳过 → metallib 管线**留壳工程**（ios/project.yml postBuildScripts，SRC
  指向 Pod 内 .metal）；③scheme 必须在 project.yml **显式声明**（xcuserdata 里的
  scheme 被 xcodegen 重生成清掉后，自动补的 scheme 不含 App target = 零 phase 假成功）。
- 凡依赖 SharedUI 的 Pod 必须自带 `SWIFT_INCLUDE_PATHS`（CChuanqiCut module 可见性，
  ChuanqiCutCamera.podspec 有现成模板）。

## 下一个会话怎么接手

1. **阶段批数字（已出）**：**PASS=12 / FAIL=0 / SKIP=0**（2026-10-07 17:49~18:04）
   —— deps/headers/artifacts/core-dbg 45/45/core-rel 45/45/xcframework/prepare/
   bindings/sharedui/player/camera/golden。新基线 = 12 步。
2. **阶段 2（INFRA-016 Import）**：迁 SharedUI/MediaPicker（7 文件）+ UIA-009/011/012。
   开工前全符号跨域引用分析（PickerFeedback 教训：查未限定标识符）。
3. **真机一趟两单**（池 [1] 播放器 5 检查点 + [2] CAM-018/019 五项）——注意本轮动过
   metallib 管线与 CameraView 公开化，真机走查务必含「首页→相机→拍摄→磨皮→录制→
   进编辑器」全链（EditorEntryInjector 是新装配路径）。执行前 `build_core_apple.sh
   --config=Debug && bindings/swift/prepare.sh`（P70），**设备保持解锁**（P64）。
4. 发号水位：ADR 下一号 **0032**；pitfalls 下一号 **P86**（已用 P83/P84/P85）；
   INFRA-016/017/019/020 未建卡。

## 验证

- Camera 包 swift test 36/36（macOS 契约）；SharedUI 52/52；Player 52/52。
- iOS BUILD SUCCEEDED（scheme ChuanqiCutApp，iphonesimulator）；metallib 8431B
  且 kernelNames 齐全（script 时间戳 = 构建时刻）；macOS BUILD SUCCEEDED（3 pods）。
- 全量门禁：见当日日志。
