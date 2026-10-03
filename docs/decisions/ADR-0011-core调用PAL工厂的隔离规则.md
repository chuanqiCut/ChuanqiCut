# ADR-0011：core 调用 PAL 工厂的隔离规则

- **状态**：已接受（2026-10-02，BIND-003 子步骤 5 落地时确立）
- **相关**：ARCH-001 §2、ARCH-003 §2.1/§2.3、ADR-0002（薄 GPU 抽象）、红线 #6（Shader 双层）

---

## 1. 被改变的既有惯例

**原惯例**：core 从不调用 PAL 工厂。

实证（2026-10-02 全库 grep）：`CreateGraphicsDevice` / `CreateMediaDemuxer` /
`CreateFrameProvider` / `CreateMediaMuxer` 的调用**只出现在** `tests/` 与 `pal/`，
`core/` 下零处。

**理由**：`cq_core` 若引用 PAL 符号，没有 PAL 后端的平台（当前 Android / HarmonyOS
均无实现）会在链接期失败。

## 2. 为什么必须开这个口子

BIND-003 的 C ABI 预览要做装配：

```
cq_preview_create()  →  CreateGraphicsDevice（PAL）
                     →  CreateBlitPass（PAL）
                     →  CreateFrameProvider（PAL）
```

三个都是平台能力。不开口子只剩两条路，都不成立：

| 选项 | 问题 |
|---|---|
| C ABI 按平台分裂实现（`pal/apple/cq_sdk_preview.mm` 等） | `cq_sdk.h` 作为「对外唯一边界」（ARCH-001 §4.1）被架空：同一份 ABI 契约出现多份实现，且每端各自演进必然漂移 |
| core 直接调 Apple 专属符号（`cq::apple::CreateBlitPass`） | 比调 PAL 工厂更糟——连「平台差异由 PAL 吸收」这层都跳过了 |

选它们的共同根因是：**把「core 不能依赖平台」误读成「core 不能依赖平台能力」**。
PAL 的存在意义恰恰是让 core 能以平台无关的方式拿到平台能力。

## 3. 决策

**允许 core 调用 PAL 工厂，但必须隔离在独立翻译单元（TU）。**

规则：

1. 调用 PAL 工厂的代码**单独成 TU**，不得并入其它 TU。
2. 该 TU 只负责「装配」，不放业务逻辑。
3. 新增此类 TU 时，必须留一个**不链 PAL 的目标**做回归验证。

原理：静态库按 **archive member 粒度**拉取符号。只要调用方没有引用该 TU 中的
任何符号，链接器就不会把它拉进来，其未定义的 PAL 符号也就不会暴露。

当前符合规则的 TU：

| TU | 调用的 PAL 工厂 |
|---|---|
| `core/src/media/pal_frame_provider.cpp` | `CreateFrameProvider` |
| `core/src/preview/cq_sdk_preview.cpp` | `CreateGraphicsDevice` / `CreateBlitPass` / `CreateFrameProvider` |
| `core/src/media/media_probe_abi.cpp`（2026-10-03） | `CreateFrameProvider`（时长探测：打开→读 duration→关闭） |

## 4. 实证

`cq_tests_c_abi`（session ABI 用例）在 CMake 中只链 `cq_core`、**不链** `cq_pal_apple`，
仍然链接通过并运行成功 → 隔离成立。

反证：若把 `cq_sdk_preview.cpp` 的内容并入 `cq_sdk.cpp`，该测试会立刻链接失败
（未定义 `cq::CreateBlitPass` 等）。这条即回归守卫。

## 5. 附带决策：抽象该放哪层，看实现必然落在哪

本次把 `IBlitPass` 从 `core/include/cq/gfx/` 移到了 `pal/gfx.h`。

理由：它**必然**由平台原生 shader 实现（红线 #6：MSL / GLSL ES 只允许出现在
`pal/<platform>/`）。若抽象留在 GFX 层，PAL 实现它就要反向 include GFX 头，
依赖方向直接冲突。

推论规则：**判断抽象放哪一层，看它的实现必然落在哪里。**

- 实现只能用平台原生能力（shader 源码、平台 SDK）→ 抽象放 **PAL**
- 上层需要用这类 PAL pass 时，走逃生口，由上层把底层句柄传下去：
  - `IGfxDevice::PalDevice()`（既有）
  - `IGfxEncoder::PalEncoder()`（本次新增，供 PAL 层 pass 接收 PAL 编码器）

## 6. 影响与例外

- 未使用预览能力的目标：不受影响（隔离生效，见 §4）。
- Android / HarmonyOS：目前**没有** PAL 实现，故一旦调用预览 ABI 会链接失败。
  这是**诚实暴露**「该端暂无预览能力」，不是缺陷；与红线 #3 一致——
  缺失能力应在运行时/链接期如实暴露，不伪造空实现。
- 将来若要支持「预览能力可选编译」，应走 CMake option 而非在代码里 `#if` 屏蔽。

## 7. 复核清单（改这条规则前先自查）

- [ ] 新增的 PAL 工厂调用是否在**独立 TU**？
- [ ] 该 TU 是否只做装配？
- [ ] `cq_tests_c_abi`（只链 cq_core）是否仍然通过？
