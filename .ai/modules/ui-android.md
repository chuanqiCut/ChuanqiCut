# 模块：Android UI（Compose）

> **归属**：A 线（编辑器/UI） —— 归属表见 docs/tasks/PLAN-三线并行.md §1a / ADR-0029（双机分工与门禁跑批，2026-10-07）

**边界**：`apps/android/app/`、`apps/android/cqbind/`

## 原则
同 Apple：UI 不共享，共享会话与命令。全部业务逻辑经 JNI 到 C++ 内核。

## 硬约束
1. UI 不得直接改模型，走 Command
2. **时间线自绘**（Compose `Canvas`），不做组件堆叠
3. 预览用 `SurfaceView` / `TextureView` + `ANativeWindow`，**不经 UI 合成**
4. 处理返回键与手势导航
5. 缩略图/波形异步，主线程不解码

## 与 iOS 的差异
- 返回键语义、手势导航、权限模型不同
- 分区存储：不能绝对路径访问
- 生命周期：配置变更与进程重建要能恢复编辑状态（依赖项目自动保存）

## 验证
```bash
./gradlew :app:testDebugUnitTest
./gradlew :app:connectedAndroidTest   # 需设备
```

## 相关
ARCH-005、`UID-0xx` 任务
