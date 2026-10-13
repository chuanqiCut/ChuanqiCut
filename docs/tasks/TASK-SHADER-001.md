# TASK-SHADER-001：Portable Shader 编译链（双层机制的地基）

> **状态：🔧 代码完成 + 链通实测；双壳构建 iOS SUCCEEDED / macOS 复跑中；真机问卷未回收**（2026-10-12）。
> spike 实测：glslang `-V --target-env vulkan1.1` → spirv-cross `--msl` →
> `xcrun -sdk macosx metal -c` rc=0。产物 `build/generated/shaders/blit_msl.h` 不入库。
> 壳工程接线（podspec `script_phases` + HEADER_SEARCH_PATHS）由集成机补齐，见下。

```yaml
id:          SHADER-001
layer:       跨平台（工具链）+ 平台消费
goal:        Portable GLSL 450 → SPIR-V → MSL 的构建期转译链落地；blit shader 从
             手写 MSL 改为 Portable 唯一事实来源（红线 #6 双层机制的第一步）
input:       [红线 #6（shader 双层）, .ai/modules/shader.md, ADR-0034（B0 批次纪律）]
output:      [shaders/src/blit.{vert,frag}(新), tools/shaders/build_shaders.py(新),
             engine/platform/apple/CMakeLists.txt(custom command),
             engine/platform/apple/gfx/blit_pass.mm(改吃生成头),
             engine/ChuanqiCutCore.podspec(script_phases + header search path)]
write_set:   shaders/src/*(新)、tools/shaders/build_shaders.py(新)、
             engine/platform/apple/CMakeLists.txt、engine/platform/apple/gfx/blit_pass.mm、
             engine/ChuanqiCutCore.podspec、engine/platform/apple/gfx/shaders/blit_fullscreen_msl.h(删)
read_set:    .ai/modules/shader.md、engine/platform/apple/gfx/blit_pass.mm(原手写 MSL)
deps:        [RENDER-001（同一批 B0）]
acceptance:
  - glslang 16.0.0 + SPIRV-Cross 源码集成（third_party/src/，scope=build，产物不入库）
  - 链路 spike：blit.{vert,frag} → SPIR-V → MSL → `xcrun metal -c` rc=0
  - CMake 侧：custom command + `cq_shaders_msl` target + include 生成目录；
    preview_renderer 像素断言全部保持（uv 约定未漂）
  - Xcode 侧：podspec script_phases（before_compile）+ HEADER_SEARCH_PATHS；
    两端 pod install 后 iOS 壳构建 SUCCEEDED
  - 手写 MSL（blit_fullscreen_msl.h）退役，blit_pass.mm 只保留「MSL 是 Metal
    能吃的格式」这一层事实
verification:
  - tools/build/build_core.sh --platform=apple   # 含 preview_renderer 像素断言
  - ctest --test-dir build -R preview_renderer   # 51 项
  - cd apps/apple/ios && bundle exec pod install && xcodebuild -workspace ChuanqiCut.xcworkspace
    -scheme ChuanqiCutApp -destination generic/platform=iOS build   # SUCCEEDED
  - cd apps/apple/mac && bundle exec pod install && xcodebuild -workspace ChuanqiCut.xcworkspace
    -scheme ChuanqiCutMacApp -arch x86_64 ONLY_ACTIVE_ARCH=YES build
risk:        工具链二进制不在库（fresh clone 须先 tools/deps 构建 glslang/SPIRV-Cross）；
             CI 无壳构建步骤（池 [18]）→ Xcode 侧接线只在本机验证过；
             UI 侧 PreviewFrameRenderer.swift 仍持有一份手写 MSL（未并入 Portable 链，
             已登记为待办，不在本批动）
parallel:    true（与 RENDER-001/MODEL-003 写集不相交）
```

## 集成缺口记录（集成机 2026-10-12 补齐）

shader agent 交付时**只接了 CMake 侧**（`engine/platform/apple/CMakeLists.txt` 的
custom command 生成 `blit_msl.h`）。Pods/Xcode 构建不经过 CMake：

1. `blit_pass.mm` 的 `#include "blit_msl.h"` 在壳工程里**没有生成源** → 直接编不过；
2. Pods.xcodeproj 是文件清单快照，还留着已删除的 `blit_fullscreen_msl.h`
   （P107 同款：旧清单会编已不存在的文件）。

处置（**没有回退成手写 MSL** —— 那正是 ADR-0014 两套渲染路径的复刻）：

- `ChuanqiCutCore.podspec` 声明 `script_phases`（`:before_compile` 跑
  `tools/shaders/build_shaders.py`，产物落仓库根 `build/generated/shaders/`，
  与 CMake 侧同一路径、同一份幂等产物）+ `HEADER_SEARCH_PATHS` 补该目录；
- 两端各跑一次 `bundle exec pod install` 刷新清单。

已知警告（无害，不处理）：script phase 无 outputs → 每次构建都跑（约百毫秒，
换来"永远新鲜"）；Copy Headers 重复 `chq_gfx.h`（P96 既有噪音）。
