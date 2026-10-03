// ChuanqiCut — 不可变模型快照（UIA-009 子步骤 2）
//
// 会话状态对外读的**唯一形态**：Timeline 与 AssetRegistry **配对**发布，
// 读侧一次加载即得版本一致的组合 —— 不存在「时间线是 v3、素材表是 v2」的撕裂。
//
// 发布方：EditorModelState（session 线程，每次成功变更后重建并替换）。
// 读取方：预览渲染器（渲染入口加载一帧所需快照）、C ABI 查询、测试。
//
// 不可变约定：持有方**绝不**修改内容；下一段状态 = 新的 ModelSnapshot 实例。

#ifndef CQ_MODEL_MODEL_SNAPSHOT_H_
#define CQ_MODEL_MODEL_SNAPSHOT_H_

#include <memory>

#include "cq/media/asset_registry.h"
#include "cq/model/timeline.h"

namespace cq {

struct ModelSnapshot {
    std::shared_ptr<const Timeline> timeline;
    std::shared_ptr<const AssetRegistry> assets;
};

// 快照提供者：返回最近一次发布的不可变快照（任意线程可调）。
// 线程约定：实现须保证跨线程调用安全（EditorModelState 用 mutex 保护，
// 持锁时长 = 一次 shared_ptr 拷贝）。
class IModelSnapshotProvider {
public:
    virtual ~IModelSnapshotProvider() = default;
    virtual std::shared_ptr<const ModelSnapshot> CurrentSnapshot() const = 0;
};

}  // namespace cq

#endif /* CQ_MODEL_MODEL_SNAPSHOT_H_ */
