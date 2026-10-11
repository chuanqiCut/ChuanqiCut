# TASK-CAM-035：P3 蒙版语义 + 美白重做 + 半分辨率链

> SPEC：SPEC-CAM-033-035 §3.P3；RESEARCH-015 决策 3/4；状态：**待开工（P1 后，与 P2 可换序）**

| 字段 | 内容 |
|---|---|
| layer | Implementation + 契约层蒙版几何 |
| goal | 蒙版覆盖脸+额际+颈且背景不变（断层根治）；美白不塑料；美颜链半分辨率 |
| input | RESEARCH-015 §决策3/4、FaceMask、CameraBeauty、VNGeneratePersonSegmentation |
| output | Impl `Detection/PortraitSegmentation.swift`(新) + FaceMask 交集几何 + CameraBeauty 美白重做 + 半分辨率包装 |
| write_set | `Detection/PortraitSegmentation.swift`(新)/`FaceMask.swift`/`CameraBeauty.swift`/`CameraRenderer.swift`(process 包装)/测试 `PortraitSegmentationTests`(新)/`FaceMaskTests` |
| read_set | CameraBeauty（P1 产物）、FaceBoxStore（P1 metadata 脸框）、baselines |
| deps | **依赖 CAM-033**（CameraBeauty.swift + 脸框来源写集/数据相交，禁止并行） |
| acceptance | mask 交集几何单测；半分辨率链 extent 不变；真机录像核验蒙版区域；处理 ≤5ms [E] 落 baselines；传哲目检人工终验 |
| verification | swift test；iOS 壳构建；真机录像回传 + 目检 |
| risk | 分割 mask 帧间闪烁（15Hz+EMA+羽化，超阈值降 .fast 档或回椭圆蒙版——开关保留）；iOS 15+ API 无门控风险（部署目标 16） |
| parallel | 与 031 无冲突（写集不相交，kernel vs 蒙版/美白），可并行（同模块串行稳） |
| 挂接 | 媒体管线：`cq-media-pipeline`（每帧热路径 + 15Hz 分割线程边界） |

## 子步骤

1. [ ] PortraitSegmentation：VNGeneratePersonSegmentationRequest（.balanced）+ 15Hz + mask EMA + 线程模型（检测队列，不阻塞采集）
2. [ ] 蒙版几何：分割 mask（上采样）∩ 脸框椭圆，羽化 ≥框宽 20%（纯函数可测）
3. [ ] 美白重做：亮度曲线（高光保护）+ 肤色饱和度微降，并入单次混合链
4. [ ] 半分辨率包装：process() 美颜子链 540×960 → 上采样混回（美型 warp 留全分辨率、拍照不降）
5. [ ] 单测 + 双壳构建 + 真机录像核验 + 目检（传哲）
