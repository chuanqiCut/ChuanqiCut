# TASK-MODEL-004：空间变换、层级、变速与关键帧数据槽（B5.5 空间与交互地基第一块）

> **状态：📋 已立卡，未开工**（2026-10-13，ADR-0040 拍板；排在 B4 之后、B6 之前）。
> 前置：B0 已提交（`2e8b55d`）但**真机问卷未回收**，按 ADR-0034 本卡须在 B4 之后开工。

```yaml
id:          MODEL-004
layer:       跨平台
goal:        给 ChqClip / ChqTrack 立起「空间 + 时间变速 + 关键帧」的数据承载：
             ChqTransform（位移/缩放/旋转/镜像/相对尺寸）+ 显式 layer（渲染层级）
             + speed（变速）+ keyframes（关键帧数据槽）。
             本卡只立数据，不做渲染消费、不做 UI 交互
input:       [ADR-0040（本卡依据）, RESEARCH-016 §2.3（ChqClip vs 其轨道槽位模型 缺口表）,
             RESEARCH-010 §5.2（B5.5 批次）, ADR-0039（Chq 前缀）, 红线 #4（有理数时间）,
             .ai/modules/model.md]
output:      [cq/model/chq_transform.{h,cpp}(新), chq_timeline.{h,cpp}(挂 transform/speed/
             keyframes + 方法), chq_editor_model_state.cpp(digest 扩字段),
             tests/unit/test_model_transform.cpp(新), tests/CMakeLists.txt]
write_set:   engine/core/cq/model/chq_transform.{h,cpp}(新)、
             engine/core/cq/model/chq_timeline.{h,cpp}、
             engine/core/cq/model/chq_editor_model_state.cpp、
             tests/unit/test_model_transform.cpp(新)、tests/CMakeLists.txt
read_set:    cq/base/chq_rational_time.h、cq/model/chq_property.h（MODEL-003 属性袋）、
             tools/platform/check_platform_headers.py
deps:        [MODEL-001, MODEL-002, MODEL-003（属性袋是本卡关键帧的实现基础）, B4]
acceptance:
  - ChqTransform 默认值必须是恒等变换：新建 clip 不填 transform 时，渲染结果
    与改动前逐像素一致（B5.5 是回归型地基，看得出来就是 bug）
  - 位移归一化到画布，原点与方向沿用既有约定（不得另立一套坐标语义）；
    与 CIContext 显式 gamma sRGB / 检测坐标左上原点归一化 保持一致
  - relative_width/height 相对 parent；改画布比例时按约定同步修正子元素，
    「改比例后子元素漂移」必须有单测锁死（对标平台对应注释：不同步修正则子元素错乱）
  - layer 为显式整数（不靠数组顺序）：同 layer 时次序稳定不漂移；
    layer 变化必须影响 digest
  - speed 语义明确：时间线占时 = 源时长 / speed；speed <= 0 一律 kInvalidArgument；
    与既有 duration/source_duration 的关系写进头文件注释（不得只活在对话里）
  - 关键帧取「属性子集快照」，**不得深拷贝整个 ChqClip**
    （对标平台为每个关键帧克隆整个 Slot，内存膨胀；本仓有属性袋，按 key 快照更省）
  - digest 覆盖 transform / layer / speed / keyframes 全部新字段：
    改任一字段指纹变，同值 set 指纹不变（内容语义，与 MODEL-003 同纪律）
  - 契约头门禁 PASS（标量用 float 不用 double）
  - 新增字段不得破坏既有序列化/B3 前置假设：若 B3 尚未做，序列化层须可扩展
```

## 设计约束（开工前必读）

1. **只立数据，不做渲染消费**：渲染归 RENDER-011 / B7，UI 交互归 B6/B7。
   本卡交付时画面必须与改前一致 —— 与 B0 同型的回归型地基。
2. **不引入第二套坐标或时间语义**：红线 #4 有理数时间、既有归一化约定一律沿用。
   对标平台的教训（`splitFromTime` 注释写微秒实为 `NSTimeInterval`）不得复现。
3. **关键帧粒度**：按属性 key 快照，不整 clip 深拷贝。理由见 acceptance 与 ADR-0040 §2。
4. **layer 必须显式**：继续用数组顺序表达叠放会导致多轨（B7）无法落地。

## 与 RESEARCH-016 的对应

| RESEARCH-016 发现 | 本卡处置 |
|---|---|
| ChqClip 无 transform / rotation / scale / mirror | 新增 `ChqTransform` 并挂到 clip 与 track |
| 无 layer（靠数组顺序） | 新增显式 `layer` 整数 |
| 无 speed | 新增 `speed` |
| 无 keyframes | 新增关键帧数据槽（属性子集） |
| 无 relative 布局（改比例子元素漂移） | 新增 `relative_width/height` + 改比例同步修正 |
| 只有 `track.muted` 布尔，无 audioFilter | **不在本卡**：片段音量归 B5（EDIT-011） |

## 验收命令（开工时实跑并写数字，不写「全绿」）

```bash
tools/build/build_core.sh --platform=apple --config=Debug     # -Werror
tools/build/build_core.sh --platform=apple --config=Release
/Users/zhuning/.workbuddy/binaries/cmake/CMake.app/Contents/bin/ctest --test-dir build
```

> ⚠️ `ctest` **不在 PATH**，须用上列全路径（本机 cmake 在 `~/.workbuddy/binaries/cmake/CMake.app`）。

交付后按 `docs/reviews/TEMPLATE-真机问卷.md` 出问卷，**问卷未回收不得标记完成**。

---

## 签名

- 立卡：WorkBuddy（集成机），2026-10-13
- 依据：ADR-0040（传哲 2026-10-13 拍板「B4 之后、B6/B7 之前」）+ RESEARCH-016
