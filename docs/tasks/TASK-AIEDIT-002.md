# TASK-AIEDIT-002：视觉特征提取管线（镜头边界/运动/质量）

```yaml
id:          AIEDIT-002
layer:       SDK
goal:        对已导入素材离线提取视觉特征（镜头段/运动强度/质量分），产出 FeatureReport.video 段
input:       [AIEDIT-001 契约, SPEC §5.1, .ai/modules/media.md, core/include/cq/media/frame_provider.h]
output:      [core/src/ai/analysis/ 实现, 单测, baselines 回填位]
write_set:   core/src/ai/analysis/*(新: visual_analyzer.{h,cpp}, scene_cut.{h,cpp}, quality_score.{h,cpp})、
             core/src/ai/analysis/feature_builder.{h,cpp}(新, FeatureReport 组装)、
             core/tests/test_visual_analyzer.cpp(新)、core/CMakeLists.txt(登记)
read_set:    core/include/cq/ai/feature_report.h, core/include/cq/media/*, core/src/media/*, .ai/modules/ai.md
deps:        [AIEDIT-001]
acceptance:
  - golden 视频集（≥5 条，含硬切/渐变/运动/静止）镜头边界数与人工标注一致（每条误差 ≤1 处）
  - 运动强度/质量分单调性检验：构造的高运动帧序列得分 > 静止序列；高斯模糊帧质量分 < 原帧（量化断言）
  - 采样上限生效：1 小时视频分析内存峰值 < 200MB [E]（-fsanitize=address 下无泄漏，数字实测回填）
  - 全程无主线程依赖；CancelToken 中途取消在 500ms 内返回 [E]
  - ctest -R visual_analyzer 全绿；build_core.sh -Werror 通过
verification:
  - ctest --test-dir build -R visual_analyzer
  - tools/build/build_core.sh --platform=apple
risk:        纯算法镜头边界对渐变转场误检 → 双判据（直方图 χ² + 像素差分）取或，渐变段保守合并；误检率不达标注精度则 P1 换模型（能力运行时查询，非 #if）
parallel:    true（批次 2，与 003/004/006/011 写集不相交）
```

## 背景

SPEC §5.1。特征是"素材不出设备"承诺的载体（ADR-0016 决策 1）——只输出聚合统计。P0 零模型依赖（人脸项置 null，AI-010 就绪后运行时替换）。

## 实现要点（挂 cq-media-pipeline 分析：seek/内存/取消）

1. 取帧走 FrameProvider 精确 seek；采样 ≤4fps、上限 600 帧/素材，降采样 160px 灰度/HSV 双流。
2. 镜头边界 = 直方图 χ² 距离 + 像素差分双判据；边界 0.5s 内的连续触发合并为渐变段。
3. 特征聚合到 shot 粒度；`feature_builder` 负责 asset 粒度组装与 `cross`（排序/去重/高光加权）——cross 的加权系数集中一处可调。
4. 人脸：P0 `faces = null` + `face_backend_available = false`；后续 AI-010 注册后运行时查询决定填充（红线 3）。

## 验收

golden 夹具视频放 `core/tests/fixtures/ai/`（≤10MB 总量，登记进 golden manifest，属测试夹具按 AGENTS.md 例外提交）。

## 回写

baselines.md 回填实测（内存峰值/单素材分析耗时）；pitfalls 记录误检案例。
