// ChuanqiCutDraft — 草稿域（骨架占位，INFRA-020）
//
// 草稿功能（草稿箱索引/自动保存/崩溃恢复）依赖 PROJ-001 项目序列化
// （core/src/project/，当前零实现）。PROJ-005 / UIA-029 落地时在此填肉；
// 引用素材走 ChuanqiCutAssets（LIB-001 契约冻结后建域，草稿引用素材不拷贝）。

/// 域占位符号：保证骨架可编译、Pod/包有实际产物；首个功能落地时删除。
public enum ChuanqiCutDraftDomain {
    /// 域版本（随主仓 0.1.0）
    public static let version = "0.1.0"
}
