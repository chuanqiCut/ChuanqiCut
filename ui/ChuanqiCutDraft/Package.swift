// swift-tools-version:6.1
import PackageDescription

// ChuanqiCutDraft — 草稿域骨架（ADR-0031 阶段 5 / INFRA-020）
//
// **骨架占位**：草稿逻辑（草稿箱/自动保存/恢复）压在 PROJ-001（项目序列化，
// core/src/project/ 尚未实现）上——PROJ-001 落地后按 PROJ-005/UIA-029 填功能，
// 引用素材走 ChuanqiCutAssets（LIB 契约冻结后建域）。

let package = Package(
    name: "ChuanqiCutDraft",
    platforms: [ .iOS(.v16), .macOS(.v15) ],
    products: [ .library(name: "ChuanqiCutDraft", targets: ["ChuanqiCutDraft"]) ],
    targets: [
        .target(name: "ChuanqiCutDraft", path: "Sources/ChuanqiCutDraft")
    ]
)
