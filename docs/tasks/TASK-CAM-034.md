# TASK-CAM-034：P2 磨皮内核（引导滤波 + 纹理保留系数 k）

> SPEC：SPEC-CAM-033-035 §3.P2；RESEARCH-015 决策 2；状态：**待开工（P1 后）**

| 字段 | 内容 |
|---|---|
| layer | Implementation（Metal kernel）+ 契约层映射纯函数 |
| goal | 磨皮观感换代（磨得净+细节保留可调），pass 提速 3-5×[E]，参数真机定标 |
| input | RESEARCH-015 §决策2、beauty_bilateral.metal、beauty_harness 工具 |
| output | 新 kernel（guided box H/V + k 混合）+ BeautyKernel 装配 + 滑杆映射 |
| write_set | `Effects/beauty_guided.metal`(新)/`BeautyKernel.swift`/`BeautyKernelProfile`(BeautyKernel.swift 内)/`CameraView.swift`(metallib 扫描名不变，预计零改)；测试 `BeautyKernelProfileTests` |
| read_set | beauty_bilateral.metal（对照/降级）、beauty_harness、baselines「相机磨皮」 |
| deps | 无硬依赖（与 030 写集不相交）；建议 030 后开工（同模块串行） |
| acceptance | harness 方差压降≥50×/边缘保持≥70%/k 单调（真机数字落 baselines）；extent 不变/off 直通/强度单调单测；耗时≤现实现 |
| verification | swift test；beauty_harness（真机）；浮层 processing ms 前后对比 |
| risk | 引导滤波参数真机表现未定（不达标不换：旧 kernel 保留降级路径）；metallib 双 -fcikernel 坑已解（ADR-0021） |
| parallel | 与 030 可并行（写集不相交），同模块串行执行；与 032 无冲突（032 不碰 kernel） |
| 挂接 | shader 任务：`cq-shader-portability`（相机特效域边界 ADR-0014 §3）；媒体管线：`cq-media-pipeline`（每帧热路径） |

## 子步骤

1. [ ] kernel：半分辨率 box blur H/V 两 pass + 引导(原图)混合 + k 纹理保留
2. [ ] 滑杆映射纯函数：strength → (r, eps, k)，r 单调不减 / k 单调不增
3. [ ] BeautyKernel 装配（新 kernel 名扫描；旧 kernel 开关保留）
4. [ ] harness 真机定标 r/eps/k → baselines（估算数字全部替换）
5. [ ] 单测 + 双壳构建 + 真机观感目检（传哲）
