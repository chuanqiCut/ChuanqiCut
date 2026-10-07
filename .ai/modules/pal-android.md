# 模块：Android 平台适配（PAL）

> **归属**：集成机（P2 预留） —— 归属表见 docs/tasks/PLAN-三线并行.md §1a / ADR-0029（双机分工与门禁跑批，2026-10-07）

**边界**：`pal/android/`、`apps/android/`、`bindings/kotlin/`

## 基线
minSdk **26 (Android 8.0)**｜ABI **arm64-v8a only**｜NDK r27+｜C++20 + libc++_shared｜Kotlin + Compose

## 技术映射
| 能力 | 实现 |
|---|---|
| 解封装 | MediaExtractor（顺序）/ FFmpeg（精确 seek） |
| 硬解 | MediaCodec（**异步 callback 模式**） |
| 硬编 | MediaCodec |
| 封装 | MediaMuxer |
| GPU | **GLES 3.1（基线）+ Vulkan（旗舰可选）** |
| 零拷贝 | `AHardwareBuffer` → EGLImage / VkImage |
| 音频 | **Oboe**（AAudio → OpenSL 回退） |
| 推理 | TFLite（NNAPI / GPU / XNNPACK） |
| 存储 | Scoped Storage + MediaStore |

## 已知坑
1. **MediaCodec 两种输出模式**：Surface 模式可零拷贝但无法读回 CPU；Buffer 模式可读回但有拷贝。默认 Surface + 零拷贝，需 CPU 访问或命中黑名单时降级 Buffer。
2. **seek 只有关键帧级** → 统一为精确 seek 语义，内部 seek 到关键帧后向前解码
3. **YUV stride 对齐与 iOS 不同** → PAL 内统一转换
4. **硬解实例数受限**（部分芯片仅 1–2 路）→ DecoderPool 调度 + 降级
5. **厂商 ROM 的 EGLImage / Vulkan 实现缺陷** → 设备黑名单 + 运行时降级
6. **NNAPI 碎片化** → 必须 XNNPACK(CPU) 回退

## 硬约束
1. 业务逻辑不得写在 Kotlin 侧
2. 权限最小化：`READ_MEDIA_VIDEO`（API 33+），导出优先走 SAF 而非全局写权限
3. **不适配低端机**：硬件门槛 = `minSdk 26` + RAM ≥ 6GB + GLES 3.1。不满足 → 明确提示不支持，**不做降级适配**

## 关于降级（别混淆）
- ❌ 低端适配：不写（极简效果链、超低分辨率代理、4GB 内存裁剪）
- ✅ 能力缺失降级：保留（无硬解→软解、无 compute→fragment、外部内存导入失败→CPU 拷贝）。**中端机也可能缺某项能力**

## 验证
```bash
./gradlew :app:assembleDebug
./gradlew :cqbind:test
tests/e2e/android/device_matrix.sh    # 仅高端 + 中端
```

## 相关
ARCH-004 §4、`PALD-0xx` 任务

---

## 模块册（ADR-0030：任务/进度/测试门禁记录按模块归口）

> 本节由归属线更新（一机一线，天然单写者）；BACKLOG / pitfalls / baselines 等
> 全局册零直写（集成机阶段批落账）。新调研/规格/审查落 docs/ 原位，但必须在此登记指针。

### 任务与进度（在飞 + 近期；全量 DAG 见 TASK-BACKLOG）

| Task ID | 标题 | 状态 |
|---|---|---|
| — | 首次落账于下一阶段批；历史状态见 TASK-BACKLOG | — |

### 测试与门禁记录（阶段批）

| 日期 | 阶段/范围 | 结论（数字） |
|---|---|---|
| — | 未实测（本模块无独立阶段批记录） | — |

### 调研 · 决策 · 池指针

- ADR-0007/0010（鸿蒙 P2 预留）· INFRA-008（接口编译检查 target）
