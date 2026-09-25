# 模块：Apple UI（SwiftUI）

**边界**：`apps/apple/packages/SharedUI/`、`apps/apple/iOSApp/`、`apps/apple/MacApp/`

## 原则
**UI 不跨平台共享，共享的是会话状态与命令**（ARCH-005）。

```
用户手势 → SwiftUI → execute(Command) → EditorSession(C++) → 快照 → UI diff 刷新
                                                          └→ 渲染请求 → RenderGraph
```

## 硬约束
1. **UI 不得直接改模型**，一切变更走 Command
2. **时间线必须自绘**（Metal/Canvas），不得把每个片段做成 UI 组件 —— 数百片段会直接掉帧
3. 拖拽只更新"拖拽预览层"，拖拽结束才提交 Command
4. 缩略图与波形异步加载，主线程不解码
5. **预览画面不经 UI 合成路径**：`MTKView` 直接绘制
6. 平台差异（iOS 手势 vs Mac 菜单/快捷键）用 `#if os(iOS)` 收敛到最小

## 性能验收
- 时间线拖拽期间主线程单帧 < 16ms
- 1080p 三轨预览 ≥ 55fps（高端机）
- 打开项目到出画面 < 1.5s（1080p）

## 验证
```bash
xcodebuild test -scheme SharedUI
# 手动：Instruments 主线程卡顿检查 + 帧率
```

## 相关
ARCH-005、`UIA-0xx` 任务
