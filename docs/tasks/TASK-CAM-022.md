# TASK-CAM-022：MetalFX 升采样（C 期）

```yaml
id:          TASK-CAM-022
layer:       UI(iOSApp)
goal:        预览链路接入 MetalFX 空间升采样（MTLFXSpatialScaler）：CI 按采集分辨率出图 →
             FX 升采样到屏幕分辨率 → 呈现 pass；降低 CI 全分辨率渲染开销，预览更省更稳
input:       [SPEC-CAM-001 §3 C 期, RESEARCH-002 §C(MetalFX 条目，A17 Pro+ 扬长清单), ADR-0014]
output:      [ChuanqiCutCameraImpl/CameraRenderer.swift(FX 升采样 pass),
             ChuanqiCutCameraImpl/Effects/MetalFXScaler.swift(封装),
             设置面板「FX 增强」开关]
write_set:   apps/apple/packages/ChuanqiCutCamera/Sources/ChuanqiCutCameraImpl/CameraRenderer.swift,
             apps/apple/packages/ChuanqiCutCamera/Sources/ChuanqiCutCameraImpl/Effects/MetalFXScaler.swift
read_set:    .ai/modules/camera.md, Apple MetalFX 文档, pitfalls P60/P65（渲染终态红线）
deps:        [CAM-015/016 渲染终态, 构建机门禁（本轮批次过编译后开工——draw 路径同一写集）]
acceptance:
  - 开关关闭时与现行链路逐位等价（默认关，不改变既有观感）
  - 运行时查询支持性（MTLFXSpatialScalerDescriptor.supports(device:)），不支持机型开关置灰
  - 真机：开 FX 后预览帧率 ≥ 关闭态（埋点 camera.preview 摘要对账），画质无可见劣化
  - 格式/usage 红线：FX 输入纹理 usage = [shaderRead, renderTarget]，输出 = [shaderWrite, shaderRead]
verification:
  - iOS BUILD（构建机）；真机帧率埋点对账归传哲
risk:        draw 关键路径改动——P60/P65 案底区，必须小步；FX scaler 需按（输入尺寸,输出尺寸）缓存重建
parallel:    false
```

## 实现要点

- 管线插位：CI → 中间纹理（帧分辨率）→ **FX spatial scaler → 全屏纹理** → 显式 UV 呈现 pass。
  FX 输出纹理以 drawable 尺寸建，呈现 pass 的 aspect-fill 采样窗按 FX 输出尺寸计算。
- 尺寸对（帧, 屏）变化时重建 scaler（转屏/换档位），缓存单实例避免每帧创建。
- 色彩：SDR 工作流 colorProcessingMode = .sdr；输入纹理格式与现行 bgra 中间纹理一致。
- ⚠️ 本卡代码在当前未提交批次过构建机门禁后接续——CameraRenderer draw 路径是本轮
  重改热区，不叠未验证改动。
