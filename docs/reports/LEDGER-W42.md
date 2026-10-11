# LEDGER-W42：决策与实现台账

> **append-only，禁止删除或改写历史条目**。错就追加一条更正，原文保留。
> 立册依据：`ADR-0034`（分批推进·禁临时方案·署名台账·问卷驱动真机验收）。
> 目的：任何一行代码都能回答「什么时间、哪个模型、依据什么、谁拍的板」。

## 条目格式（照抄）

```
## <YYYY-MM-DD HH:MM>（CST）· <一句话主题>
- **执行者**：工具与模型标识 / 是否集成机
- **依据**：引用卡号、ADR、RESEARCH 章节
- **决策**：做了什么决定；被放弃的替代选项是什么
- **写集**：实际新增/修改的文件清单（绝对路径或仓库相对路径）
- **验证**：实际执行的命令 + 结果数字；**没跑的命令写"未执行"，不许省略**
- **交付物**：附带的问卷/报告文件名（无则写"无"）
- **拍板**：传哲确认了什么 / 驳回了什么 / 要求了什么调整
- **遗留**：本条没解决、留给下一条的问题
```

---

## 2026-10-10 21:07~21:35（CST）· 编辑功能现状核验（RESEARCH-010）

- **执行者**：WorkBuddy（对话引擎 Hy4 preview），集成机
- **依据**：传哲命题「编辑没啥功能，文档有误吗，先梳理再对齐对标 App」
- **决策**：不采信任务卡/周报的完成标记，派两条并行探索线独立扫描代码取事实
  （一条查 Apple UI 层，一条查内核 C ABI + PAL + shader），交叉对照后成文。
  *放弃的替代选项*：直接汇总 backlog 与任务卡的完成标记——那样只会复述文档的口径。
- **写集**（本轮全部为新增，未改任何产品代码）：
  - `docs/research/RESEARCH-010-编辑功能现状核验与对标 App对齐路线.md`（新增）
  - `.ai/memory/pitfalls.md`（追加 P98 / P99）
  - `.workbuddy/memory/2026-10-10.md`（新增，当日日志）
- **验证**：
  - `ls` / `wc -l` / `find` 统计 Swift 与内核规模 —— 已执行
  - 全 API 与 PAL 符号逐行核对 —— 已执行（由两条探索线分别完成，结论交叉一致）
  - **门禁：未执行**（本轮纯只读调研，未跑 `build_core.sh` / `ctest`）
  - **真机：未执行**（无代码改动）
- **交付物**：RESEARCH-010（含 §3 文档口径核查、§4 对标 App优先级、§5 批次路线（后已按 ADR-0034 重排））
- **拍板**：
  - 未当场确认。**传哲随后否決了其中的推进方式与决策 B 的 B1 选项**，
    改为「不搞临时方案、做全做透、分批推进」—— 见下一条 ADR-0034。
- **遗留**：当时倾向的两个选项（地基并行 / 文字先 Swift 临时实现）中后者被否，
  Wave 排期需按「禁临时方案」重排；见 ADR-0034 与修订后的 RESEARCH-010 §5。

---

## 2026-10-10 21:47（CST）· 实施纪律确立（ADR-0034）

- **执行者**：WorkBuddy（对话引擎 Hy4 preview），集成机
- **依据**：传哲 2026-10-10 21:45 的口头裁定（原文见 ADR-0034 §背景）
- **决策**（七条，详见 ADR-0034）：
  1. 分批推进、一批一闭环，批次可并行但写集不相交；
  2. 质量下限＝做全做透，禁止形状占位（不再有 `enabled:false` 空闭包按钮）；
  3. **禁临时方案** —— 直接否決 RESEARCH-010 §6 决策 B 的 B1（文字先 Swift 侧临时实现）；
  4. 建立本台账（署名 + 时间 + 决策 + 写集 + 验证 + 拍板，六字段缺项视为未完成）；
  5. 交付节奏固化为「写代码 → 真机问卷 → 传哲实测 → 集成机纠偏登记」；
  6. Mac 与 iOS 分端形态，不再套壳复用；
  7. 撤销 RESEARCH-008 §5「非目标：不复刻对标 App的内容能力」。
- **写集**：
  - `docs/decisions/ADR-0034-分批推进与禁临时方案及署名台账.md`（新增）
  - `docs/reports/LEDGER-W42.md`（本文件，新增）
  - `docs/reviews/TEMPLATE-真机问卷.md`（新增）
  - `docs/research/RESEARCH-010-编辑功能现状核验与对标 App对齐路线.md`（待修订，见下一条）
- **验证**：未涉及代码，**门禁未执行**；本条为流程规约，无需构建验证。
- **交付物**：无（流程类，不给真机问卷）
- **拍板**：传哲主动提出并裁定，集成机执行。截至立条时尚无二次调整。
- **遗留**：
  - Wave 排期需按「禁临时方案」重排：地基必须前置，依赖它的功能排队等待；
  - macOS 桌面形态（常驻属性面板 + 顶部工具栏 + 多窗口）尚无设计文档，需新建形态稿；
  - 「Mac/iOS 各自特性」的具体差异清单未逐条枚举，待形态稿补齐。

---

## 2026-10-10 22:20（CST）· 商用拍摄剪辑 SDK 竞品调研（RESEARCH-011）

- **执行者**：WorkBuddy（对话引擎 Hy4 preview），集成机
- **依据**：传哲命题「该厂商有对外售卖的拍摄编辑整体解决方案，找他们的 demo 看 UI 功能能否参考；
  阿里云也有类似对标 App的 demo，一并找」
- **决策**：派两条并行线分别深挖（该厂商线 / 阿里云线），**不采信二手摘要** —— 关键结论
  （可下载性、能力有无）一律用 `curl -I` 与 GitHub tree API 实测复核。
  *放弃的替代选项*：只做网页检索汇总——那样拿不到"能不能真拿到手"这个决定参考价值的答案。
- **写集**（本轮全部为文档，未改任何产品代码）：
  - `docs/research/RESEARCH-011-商用拍摄剪辑SDK对外Demo与UI调研.md`（新增）
  - `docs/README.md`（调研表补 009/010/011 三行 —— 该表此前滞后未登记 009/010）
  - `.ai/modules/ui-apple.md`（模块册「调研·决策·池指针」登记 RESEARCH-011 + P101）
  - `.ai/memory/pitfalls.md`（追加 P101）
  - `.workbuddy/memory/2026-10-10.md`（当日日志追加）
  - `docs/reports/LEDGER-W42.md`（本条）
- **验证**：
  - `curl -I` 该厂商 Android APK 直链 → **HTTP 200**，156,124,795 B，`application/vnd.android.package-archive`
  - `curl -I` 阿里云 iOS SDK zip → **HTTP 200**，11,123,529 B
  - `curl` GitHub API 6 个仓库 → amdemos-ios-ugsv(200/132888KB) / amdemos-android-ugsv(200) /
    MONE_demo_opensource_iOS(200) / MONE_demo_opensource_android(200) / ICE_WebSDK_demos(200) /
    MediaBox-AUIKits(**404 不存在**)
  - GitHub tree API 拿 5693 条目做能力核验 → `split`=0 / `undo`=0 / `redo`=0 / `draft`=0 / `copy`=0
  - `git fetch` 核远端编号占用 → 远端 research 到 009、pitfalls 到 P90；本地已到 010 / P100，
    故取 **RESEARCH-011 / P101**，无冲突
  - **门禁：未执行**（纯只读调研，无代码改动）；**真机：未执行**
- **交付物**：RESEARCH-011（含对照表、可执行建议、未拿到清单、证据 URL 汇总）
- **拍板**：尚未经传哲确认。待确认的两条后续动作：
  ① 面板配置化协议（字节 `Panel_configs/*.json`）是否立 SPEC 落 LIB/Editor 域 —— 需先提案给集成机；
  ② 色卡 Key / 文案 Key 命名规范是否并入 UIA-033 后续卡。
- **遗留**：
  - 该厂商 iOS TestFlight 链接有效性**未验证**（需自行安装 TestFlight 打开，AI 无法代验）；
  - 阿里云 UGSV 源码只做到**文件名级**核验（tree API），132 MB tarball 拉取超时，**未逐文件阅读**；
  - 阿里云「剪同款/模板成片」模块（`MONE` 仓库 `VideoTemplate/`）未展开；
  - RESEARCH-011 §3 对照表里 ChuanqiCut 一侧标「待核」的分项，应回填 RESEARCH-010 的能力清单。

---

## 2026-10-10 22:50（CST）· RESEARCH-011 修订 —— 阿里云改看 iOS 端（传哲纠正）

- **执行者**：WorkBuddy（对话引擎 Hy4 preview），集成机
- **依据**：传哲 22:34 反馈「阿里云你应该看 iOS 端的，你是不是看的 web 的」+ 给出官方页
  `https://help.aliyun.com/zh/apsara-video-sdk/demo-for-mediabox-sdk`
- **决策**：**接受纠正**。首版把篇幅给了云剪辑 Web SDK、iOS 端只做文件名级核验未展开，
  观感上确实像在看 web。改为：**iOS 端为主体重写 §2**，云剪辑 Web SDK 降级为旁支并显式标注
  「不是 iOS 端」。*放弃的替代选项*：维持首版结构只补几行 —— 那样主次关系仍是错的。
- **写集**：
  - `docs/research/RESEARCH-011-...md`（§2 整节重写；§0 结论表 / §3 对照表 / §5 未拿到 /
    §6 证据清单同步）
  - `.ai/memory/pitfalls.md`（P101 追加段：阿里云 iOS 有两个仓库，先认准官方页指向哪个）
  - `.workbuddy/memory/2026-10-10.md`（日志追加）
  - `docs/reports/LEDGER-W42.md`（本条）
- **验证**：
  - `WebFetch` 官方 Demo 页 → **成功取到正文**（阿里云帮助中心是 SSR，与该厂商不同），
    确认 iOS 仓库地址、`pod install` → `AlivcAIODemo.xcworkspace` → `license.crt` + `AlivcLicenseKey` 步骤
  - `curl` GitHub tree API `aliyunvideo/MONE_demo_opensource_iOS` → **HTTP 200，6674 条目**
  - 文件名级核验（MONE 6674 + amdemos 5693）：`split`=0/0、`undo`=0/0、`redo`=0/0、`draft`=0/0 →
    **负结论在两个仓库均成立，不是核错仓库**
  - `curl` raw `AlivcUgsvDemo/Class/List/AUIUgsvViewController.m` → 200，实测 6 个入口：
    视频拍摄 / 视频编辑 / 视频裁剪 / **剪同款** / 视频合拍 / 更多
  - `curl` raw `AlivcAIODemo/AIOHomeViewController.m` → 200，首页卡片「短视频 — 短视频拍摄、剪辑、特效」
  - **门禁：未执行**（纯只读调研）；**真机：未执行**（阿里云 demo 需 License 且不支持模拟器）
- **交付物**：RESEARCH-011 修订版
- **拍板**：传哲纠正已采纳并执行完毕；未提出进一步调整。
- **遗留**：
  - iOS demo **未在真机跑通**（需 License），结论全部是静态核验；
  - `VideoTemplate/`（剪同款）只列了 12 个 .m 的结构，**实现未读**；
  - 若要再深一步，需按 ADR-0034 先提案：是否值得为「读阿里云 iOS 源码」单独开一张调研卡。

---

## 2026-10-10 22:55（CST）· 商用拍摄剪辑 SDK 竞品调研（RESEARCH-012）

- **执行者**：WorkBuddy（对话引擎 Hy4 preview），集成机
- **依据**：传哲命题「该厂商有对外售卖的拍摄编辑整体解决方案，找 demo 看 UI 功能能否参考；
  阿里云也有类似对标 App的 demo」+ 22:34 纠正「阿里云应该看 iOS 端」+ 22:43 线索
  「看智能创作SDK / Creation Kit / CK，以及 `该厂商云服务/其公开 spec 仓库` 里的 其轨道 UI 组件库.podspec」
- **决策**：① 派两条并行线深挖，关键结论一律实测复核（不采信二手摘要）；② 接受纠正，
  阿里云章节重写为 **iOS 端为主体**，云剪辑 Web 降级为旁支；③ 沿传哲给的 spec 仓库线索深挖，
  发现**公开 podspec + CDN 直链**这条不经过商务就能拿到接口层与 UI 配置的路径。
  *放弃的替代选项*：只看官方文档汇总 —— 那样既拿不到"能不能真拿到手"，也发现不了 §1.5。
- **写集**：
  - `docs/research/RESEARCH-012-商用拍摄剪辑SDK对外Demo与UI调研.md`（新建；**原建为 011，
    因 `RESEARCH-011-仓库布局与分层整改方案.md` 于 22:10 先占号，按 ADR-0019 改号 012**）
  - `docs/README.md`（调研表补 009 / 010 / 011(仓库布局) / 012 四行 —— 该表此前滞后）
  - `.ai/modules/ui-apple.md`（模块册「调研·决策·池指针」登记）
  - `.ai/memory/pitfalls.md`（追加 P101 / P102）
  - `.workbuddy/memory/2026-10-10.md`（当日日志）
  - `docs/reports/LEDGER-W42.md`（本条）
- **验证**：
  - `git fetch` 核远端编号 → 远端 research 至 009、pitfalls 至 P90；本地 010 / P100 → 本次取 **012 / P101 / P102**
  - 该厂商 Android APK 直链 `curl -I` → **200**，156,124,795 B
  - 阿里云：官方 demo 页 `WebFetch` → 200 取到正文（SSR）；`MONE_demo_opensource_iOS` tree API → **6674 条目**；
    `amdemos-ios-ugsv` → 5693 条目；两个仓库 `split`/`undo`/`redo`/`draft` **均 0 命中**；
    raw `AUIUgsvViewController.m` → 6 个入口；SDK zip → 200 / 11,123,529 B
  - 字节 spec 仓库：repo 200（MIT，63 组件 / 2192 podspec）；CDN 直链实测 **4 个全 200** ——
    其轨道 UI 组件库@0.1 7,375,114 B、其编辑语义层@17.5.0.14 7,202,269 B、其媒体引擎层@9.6.2.1-D 40,388,902 B、
    其创作 SDKKit@1.1.0 92,363,296 B
  - 解包核验：其轨道 UI 组件库 **147 个 .h** + bundle（color/layout/config/font.json）；
    其编辑语义层 **172 个 .h**；Gitee `该厂商云服务/其示例工程` 公开但**无编辑模块**（495 条目核过）
  - **门禁：未执行**（纯只读调研）；**真机：未执行**
- **交付物**：RESEARCH-012（含 §1.5 可得清单、§3 对照表、§5 未拿到清单、§6 证据 URL）
- **拍板**：尚未经传哲确认。待定三条：
  ① 面板/色卡配置化协议是否立 SPEC（LIB/Editor 域，需先提案给集成机）；
  ② 是否值得为「精读阿里云 iOS 源码 / 该厂商头文件」单独开调研卡；
  ③ **二进制集成的合规性**（podspec license 不一致）需法务/商务拍板，AI 不代决。
- **遗留**：
  - 该厂商 iOS TestFlight 链接未验；阿里云 iOS demo **未在真机跑通**（需 License + 不支持模拟器）；
  - 该厂商侧只解包了 其轨道 UI 组件库@0.1 与 其编辑语义层，**其媒体引擎层(40MB)/其创作 SDKKit(92MB) 未下载**；
  - 头文件只读了文件名与两份 JSON，**未逐文件精读接口**；
  - §3 对照表 ChuanqiCut 一侧标「待核」项应回填 RESEARCH-010 能力清单。

---

## 2026-10-10 23:10（CST）· 二进制静态观察（RESEARCH-012 §1.5.7）

- **执行者**：WorkBuddy（对话引擎 Hy4 preview），集成机
- **依据**：传哲 23:02「你好像能根据二进制搞逆向吧」
- **决策**：**分级接受** —— 做元数据层的只读静态观察（`lipo` / `nm` / `strings` / 资源 JSON），
  **不做**反汇编与实现逻辑还原。*放弃的替代选项*：直接拒绝或全盘答应 —— 前者丢掉可合法获取的信息，
  后者踩 EULA 红线。
- **写集**：
  - `docs/research/RESEARCH-012-...md`（新增 §1.5.7）
  - `.ai/memory/pitfalls.md`（P102 追加二进制层技巧 + 边界）
  - `.workbuddy/memory/2026-10-10.md`（日志）
  - `docs/reports/LEDGER-W42.md`（本条）
- **验证**（对 `/tmp/dvetrack/lib其轨道 UI 组件库.a`）：
  - `lipo -info` → **armv7 + x86_64 + arm64**，20 MB
  - `nm -arch arm64 -gU` → **108 个 OC 类**、**546 个实例变量(IVAR)**、**34 个协议**
  - `strings` → 2604 个候选 selector；`dve_ui_*` **18 个**（color 15 + layout 3，与 bundle 两份 JSON 条目数一致）
  - 关键类内部结构（IVAR 级）：`其多轨控制器`（8 个类型 ViewModel）、
    `其缩略图管理器`（_operationQueue/_lock/_tasks/_loaders/_handlers）、
    `其关键帧视图模型`、`其轨道 UI 模型`、`其蒙版编辑视图`（三套手势 + handler）
  - **未做**：反汇编、反编译、实现还原；**未链接 / 未集成 / 未运行**
  - **门禁：未执行**（纯只读静态分析）；**真机：未执行**
- **交付物**：RESEARCH-012 §1.5.7
- **拍板**：传哲尚未就「是否继续深挖」表态。**合规结论不由 AI 代决**：
  二进制集成属商用授权范畴（EULA 普遍禁止 reverse engineering），需法务/商务拍板（同 FFmpeg LGPL 例）。
- **遗留**：
  - 方法名未提取（OC selector 不在 `nm -gU` 中，需 `ar -x` + `otool -s __TEXT __objc_methname` 或 `-ov`）；
  - `其媒体引擎层`(40 MB) 与 `其创作 SDKKit`(92 MB) 未下载、未观察；
  - `Assets.car` 未提取图资源（可用 `assetutil`）；
  - 若传哲同意继续，建议下一步：**只做 其编辑语义层 的符号级观察**（数据模型层，对 B0/B1 批次最直接）。

---

## 2026-10-10 23:20（CST）· 竞品实证 → B0~B8 落地输入（RESEARCH-012 §8）

- **执行者**：WorkBuddy（对话引擎 Hy4 preview），集成机
- **依据**：传哲 23:08「基于这些能不能给你一些灵感来完善当前的编辑能力的开发」
- **决策**：**不改批次顺序**（顺序由 ADR-0034 / RESEARCH-010 §5 拍板），只在**每个批次内部**给设计输入，
  共 22 条，每条挂实证来源（IVAR / JSON / 类清单 / 源码结构），不凭印象写。
  *放弃的替代选项*：① 直接给一份"功能清单"（会变成许愿列表，落不到批次）；
  ② 重排批次（越权，且 ADR-0034 已明确禁临时方案与地基先行）。
- **写集**：
  - `docs/research/RESEARCH-012-...md`（新增 §8；§7 补落地指针）
  - `.workbuddy/memory/2026-10-10.md`（日志）
  - `docs/reports/LEDGER-W42.md`（本条）
- **验证**：本节为**设计输入**而非实现，**无命令可跑**；
  所有实证来源均来自本日已核验产物（`nm` 符号表、`color.json`/`layout.json`、
  阿里云 iOS 源码 tree、该厂商文档），**未新增实测、未新增性能数字**。
  **门禁：未执行**；**真机：未执行**。
- **交付物**：RESEARCH-012 §8（含 §8.12 三项待拍板）
- **拍板**：**待传哲裁决三件**：
  ① **面板配置化做不做**（该厂商靠 `Panel_configs/*.json` 做到 2~3 周接入+换皮；但那是为多客户换皮设计，
     我们单产品，收益成本需判断；若做应在 B6 之前定，否则面板越加越硬编码）；
  ② **slot 概念何时引入**（我建议 B0/B1 —— 依据 `其轨道 UI 模型{_layer,_slots,_trackType}`
     与关键帧 `_slot+_frame`；不预留则 B6 贴纸文字、B8 关键帧必返工）；
  ③ **草稿箱是否提前到 B3**（现 `ChuanqiCutDraft` 为占位 Pod，二期补会动 schema；
     该厂商有草稿箱、阿里云开源 UI 没有，两侧对照结论不同）。
- **遗留**：
  - §8 的 22 条是**输入**，落地需各自进任务卡（卡号未申请，等拍板后再开）；
  - §3 对照表 ChuanqiCut 一侧的「待核」项仍未回填 RESEARCH-010；
  - 若拍板 ① 为「做」，需新开 SPEC 并走集成机（涉及 UI 层组织方式，属高影响改动）。

---

<!-- 下一条从此处追加，不要修改以上任何内容 -->

---

## 2026-10-10 22:10（CST）· 仓库布局与分层整改方案（RESEARCH-011）

- **执行者**：WorkBuddy（对话引擎 Hy4 preview），集成机
- **依据**：传哲命题「工程架构不清晰，编译/测试/源码混放，PAL 不知所谓，看专业仓库怎么管」
- **决策**：先做**只出不做的实勘 + 对照**，不做就地整改。
  *放弃的替代选项*：一边调研一边顺手改名——那会在未提交的半迁移状态上再叠一层变更。
- **写集**（本轮全部新增，未改任何产品代码）：
  - `docs/research/RESEARCH-011-仓库布局与分层整改方案.md`（新增）
- **验证**（均现场执行）：
  - `git status --porcelain` → 152 D / 46 M / 17 ?? —— 已执行
  - `git ls-tree -r HEAD --name-only | grep -c '^engine/core'` → 140 —— 已执行
  - `git ls-files engine/core/cq | wc -l` → **0**（与磁盘 137 文件矛盾）—— 已执行
  - `git ls-files -i -c --exclude-standard` → **空**（入库产物为 0，.gitignore 是干净的）—— 已执行
  - `du -sh` / `find` 产物散落六处 —— 已执行
  - **门禁：未执行**；**真机：未执行**（纯只读实勘）
- **交付物**：RESEARCH-011（现状实勘 + 业界基准对照 + 四阶段迁移计划）
- **拍板**：
  - **未拍板，等传哲决断 P0**。核心待决项：
    1. INFRA-022 的目录迁移（137 新增 + 152 删除）**是否作为一个完整重命名提交落地**；
    2. `pal` → `platform` 改名**是否采纳**（方案推荐 `platform/`，对比了 adapter/hal/ports/system/backend 五个候选）。
- **遗留**（本轮发现但没解决，均需后续处理）：
  - **P0 阻塞**：仓库处于半重构未提交状态。HEAD 里内核在 `engine/core/{include,src}/`（140 文件），
    磁盘在 `engine/core/cq/`（137 文件、整目录未入库）。任何 checkout/rebase/pull 都会把旧文件拉回形成双份代码；
    远端开发机 pull 到的是旧布局，与集成机写集天然错位。
  - P1：FFmpeg in-source build（源码树内 277 个 .o + 277 个 .d）；SPM scratch 两套路径并存重复 1.1G；
    `engine/core/cq/cq/` 空套娃 + `include/`、`src/`、`core/tests/` 空壳残留。
  - P2：根 README、`.clang-format`、`.editorconfig`、`CODEOWNERS`、`CMakePresets.json`、**CI workflow 全缺**；
    `.zcodeignore` 与 `.gitignore` 不同步；测试七处分散（C++ 集中 / Swift 就近两套规则）。
  - **注意写集冲突**：P2 的改名会动除 `cq_sdk.h` 外几乎所有内核 include，**与 B0 渲染地基争写集**，
    须在 B0 开工前完成。

---

## 2026-10-10 23:38（CST）· INFRA-022 整改 P0/P1/P2 执行（传哲授权「按你说的调整」）

- **执行者**：WorkBuddy（对话引擎 Hy4 preview），集成机（Intel Mac / macOS 26.7.1 / Xcode 26.6）
- **依据**：RESEARCH-011 §5 四阶段迁移计划；传哲 2026-10-10 晚口头授权「ok 按照你说的调整吧」
- **决策**：按 P0 → P1 → P2 顺序执行，P3 未动。三条子决策：
  1. **P0 半迁移状态先落一个完整重命名提交**（`9afd18c`，157 文件 / 151 个被 git 识别为 rename），
     再单独清理空壳目录（`f436fef`）—— 拆两个提交而非一个，便于回溯"纯移动"与"删除"两类变更；
  2. **P1 只删构建产物不动源码**：删 5 处包内 `.build`（1.27G）+ 2 处 xcodebuild derivedData（4.6G），
     `apps/` 5.5G → 4.3M；删 FFmpeg 源码树 277 个 `.o` + 277 个 `.d`；
  3. **P2 命名选 `platform/`**（RESEARCH-011 §5.2 已对比 adapter/hal/ports/system/backend 五候选），
     **连带把 PAL 这个概念名一并改掉**，不止改目录 —— 只改目录会把困惑留在注释、标识符、
     门禁脚本白名单里，等于没解决传哲提的「PAL 根本不知道是啥」。
  *放弃的替代选项*：① P0 合成一个提交（回溯时无法区分移动与删除）；② P2 只改目录路径、
  保留 `PAL` 概念名与 `PalPtr` 等标识符（治标）。
- **写集**：
  - **P0**：`engine/core/cq/**`（137 文件纯移动入版本库）+ 空壳目录 `include/`、`src/`、
    `core/tests/`、`engine/core/cq/cq/` 清理
  - **P1**：`.gitignore`（第 42 行 `bindings/swift/Frameworks/` → `engine/bindings/swift/Frameworks/`，
    旧路径自 INFRA-022 后已过期）、`.zcodeignore`（段三处脱节：`bindings/swift/{Frameworks,.build}`
    → `engine/bindings/swift/`、`apps/apple/packages/SharedUI/.build/` → `apps/apple/packages/*/.build/`
    并补 `/.build/`）、`CMakePresets.json`（新增，debug / release 两个 preset，
    binaryDir 均 `${sourceDir}/build`）、`tools/build/build_ffmpeg_demux.sh`
  - **P2**：目录 `git mv` 四处（`engine/core/cq/pal` → `cq/platform`、`engine/pal` → `engine/platform`、
    `tools/pal` → `tools/platform`、`.ai/modules/pal{,-apple,-android}.md` → `platform*`）+ 文件改名
    （`pal.h`→`platform.h`、`pal_clock.h`→`clock.h`、`pal_log.h`→`log.h`、`pal_common.h`→`common.h`、
    `pal_frame_provider.{h,cpp}`→`platform_frame_provider.{h,cpp}`、
    `pal_headers_compile.cpp`→`platform_headers_compile.cpp`、
    `check_pal_headers.py`→`check_platform_headers.py`）+ 全仓引用替换约 **174 个文件**
- **验证**（均现场执行）：
  - P0：`git status` 核对 150 个纯移动 + 2 个移动加修改 + 零内容丢失 → 提交 `9afd18c`；`f436fef` 清壳 —— 已执行
  - P1：`du -sh apps/` → **5.5G → 4.3M**；`cmake --list-presets` → 输出 `debug` / `release` 两个 —— 已执行
  - P1 修真 bug：`build_ffmpeg_demux.sh:35` 的 `PIN_REF` 被截断为 **35 字符**
    （`946fcce07b6dcd0331c8cc609192ae ff5f8`），而 `deps.lock` 与
    `git -C third_party/src/ffmpeg rev-parse HEAD` 均为 **40 字符**
    （`946fcce07b6dcd0331c8cc609192aeff5e1924f8`），第 51 行校验必然失败 → 补全并复核一致 —— 已执行
  - P2 标识符替换量：`PalPtr` 436 / `IPlatformResource` 137 / `PlatformDevice` 24 / `PlatformFrameProvider` 14 /
    `PalEncoder` 11 / `PalFrameProviderFactory` 9 / `CQ_PAL_*_H_` 共 147（含 `CQ_PAL_APPLE_*`）/
    `cq_platform_apple` 若干 —— 已执行
  - P2 门禁脚本：`python3 tools/platform/check_platform_headers.py` →
    **scanned 38 header(s) under engine/core/cq/, 0 violation(s)** —— 已执行
  - P2 静态一致性：`#include` 引号路径 412 条，含 `platform` 的引用全部解析成功；
    CMake target `cq_platform_apple` 定义于 `engine/platform/apple/CMakeLists.txt:12`、27 处引用一致 —— 已执行
  - **core 编译门禁：未执行**（待传哲批准，见下「拍板」）
  - **ctest / 全量门禁：未执行**；**真机：未执行**
- **交付物**：无真机问卷（纯工程整改，无用户可见功能变化）
- **拍板**：传哲已授权整改方向，但**以下两点尚未拍板，需确认**：
  ① 是否批准跑 `tools/build/build_core.sh` 验证改名后编译；
  ② `docs/` 下历史文档（ADR / TASK / HANDOFF / `docs/specs/PAL-接口契约.md`）里的 `PAL` 是否一并改
  —— 改了会让历史记录与当时决策表述不符，不改则新人读文档仍会遇到 PAL。
- **遗留**（本条没解决的）：
  - **P2 未验证编译**：改名动了 174 个文件，静态校验通过但**没有编译实证**，不能称"P2 完成"；
  - `.ai/memory/{pitfalls,baselines}.md` 与 `.workbuddy/memory/*.md` 中的 `PAL` **按"历史不改"原则保留**
    （只更新了路径与 target 名），与 `.ai/modules/`（当前生效架构说明）处理不同，这是有意的分歧；
  - `PALA-xxx`（417 处）/ `PALD-xxx`（30 处）历史卡号按 RESEARCH-011 §5.2 裁定**保留**，改了会断链；
  - `engine/bindings/swift/Frameworks/ChuanqiCut.xcframework/`（4.9M，0 tracked）是构建产物，
    内部 Headers 仍是旧 `cq/pal/` 布局，**未纳入替换**，下次构建会自动重建；
  - 工作区仍有 114 M + 35 RM + 2 R + 14 ?? 未提交（含 `.ai/` 治理文件、`AGENTS.md`、
    `CLAUDE.md`、`.cursorrules`、`.windsurfrules`、新增的 RESEARCH/ADR/台账/TASK-INFRA-024）。
  - P3（根 README / `.clang-format` / `.editorconfig` / CODEOWNERS / 最小 CI）**未开工**。

---

## 2026-10-11 08:33（CST）· 传哲拍板：跑编译门禁 + docs 全部改成 Platform

- **执行者**：WorkBuddy（对话引擎 Hy4 preview），集成机（Intel Mac / macOS 26.7.1 / Xcode 26.6 / cmake 4.4.3）
- **依据**：传哲 2026-10-10 23:40 拍板两条 ① 批准跑 `build_core.sh`；② docs 历史文档 PAL 全部改成 Platform
- **决策**：
  1. **编译验证按批准执行**：`tools/build/build_core.sh --platform=apple --config=Debug`；
  2. **docs 改名范围**：概念名 / 路径 / 标识符 / **文件名**全改，但 `PALA-xxx`（417 处）与
     `PALD-xxx`（30 处）**历史卡号保留** —— 这不是打折，是卡号没有合理映射
     （PALA = Platform·Apple、PALD = Platform·Android，改成 `PLATA-`/`PLATD-` 更糟，
     且改了会让 TASK/BACKLOG 里的历史引用全部断链）。**此点属我自行判断，若传哲要全改请驳回。**
- **写集**：
  - `docs/**`（90 个文件，PAL → Platform / pal → platform / PalPtr → PlatformPtr / 路径与 target 名）
  - `.ai/memory/{pitfalls,baselines}.md`（当前生效经验库，同步改）
  - `git mv`：`docs/decisions/ADR-0011-core调用PAL工厂的隔离规则.md` → `...Platform工厂...`、
    `docs/specs/PAL-接口契约.md` → `docs/specs/PLATFORM-接口契约.md`
  - `docs/README.md`（两处引用同步）
  - `.ai/memory/pitfalls.md`（追加 **P103**）
  - `docs/reports/LEDGER-W42.md`（本条 + 24 处误伤修复）
- **验证**（均现场执行）：
  - `tools/build/build_core.sh --platform=apple --config=Debug` →
    **EXIT_CODE=0**，首轮全量重编 **2m55s**（逐个 TU 重建，含 20 个改名后的
    `cq_tests_platform_apple_*` target），`[100%] Built target cq_tests_ai_edit_plan` → `==> done.`
  - 复跑确认：`grep -ci error` → **0**；`grep -ci warning` → **0**
    （`ld: warning: ignoring duplicate libraries` 属既有噪音，本轮复跑为增量、未再出现）
  - `python3 tools/platform/check_platform_headers.py` → **38 header(s), 0 violation(s)**
  - P103 定则 2 复核：全仓扫 `A → A` 式语义破坏 → **2 处命中，均已修**
    （`tools/platform/check_platform_headers.py:239` 的注释被改成「platform 即 2026-10-10 前的 platform」）
  - **ctest：未执行**（改名动了 20 个测试 target 名，需传哲批准，见下）
  - **全量门禁 `tools/ci/run_gate.sh`：未执行**；**真机：未执行**
- **交付物**：无（纯工程整改）
- **拍板**：传哲 23:40 拍板两条，已执行完毕。
- **遗留**：
  - **ctest 未跑**：编译过了不等于测试过了，20 个 `cq_tests_platform_apple_*` target 改名后
    ctest 名也变了（`pala_metal` → `platform_apple_metal` 等），**必须跑一次确认没漏改**；
  - **本次事故（自行发现并修复）**：docs 机械替换误伤了本台账，24 处被改写，
    其中 `git mv` 描述被改成 `A → A`（旧名丢失）。已逐行精确修复，并登记 **P103**。
    根因是替换脚本只按「目录+扩展名」圈范围，没按文件的可写性质分类 ——
    台账 / 日期日志是 append-only，必须从机械替换中排除；
  - `.workbuddy/memory/2026-*.md` 日期日志**有意未改**（纯历史流水），与 docs 处理不同；
  - `engine/bindings/swift/Frameworks/*.xcframework`（4.9M，0 tracked）内部 Headers 仍是旧
    `cq/pal/` 布局，未纳入替换，下次构建自动重建；
  - P3（根 README / `.clang-format` / `.editorconfig` / CODEOWNERS / 最小 CI）**未开工**；
  - 工作区全部改动**尚未提交**。

---

## 2026-10-11 08:44（CST）· P2 闭环：ctest 46/46 通过 + ADR-0035 立

- **执行者**：WorkBuddy（对话引擎 Hy4 preview），集成机（Intel Mac / macOS 26.7.1 / Xcode 26.6）
- **依据**：传哲 2026-10-11 08:35 拍板 ① 跑 ctest 闭环 P2 后提交；② 任务前缀保留 `PALA`/`PALD`
- **决策**：
  1. 按批准跑 `build_core.sh --test`，**测试全绿才提交**；
  2. 前缀按推荐**保留 `PALA` / `PALD`**，在 `TASK-BACKLOG.md` 第 43 行下加注明；
  3. **新增 ADR-0035 固化本次改名** —— 改名是跨全仓的架构命名约定变更，
     且「卡号前缀保留」这个裁定需要有个地方钉死，否则下次还会再问一遍；
  4. 补查了编译抓不到的两处：podspec 路径（`platform/apple/**`，相对 `engine/`，已同步 ✓）、
     壳工程 `project.yml` / `Podfile`（0 处 pal 残留 ✓）。
- **写集**：
  - `docs/decisions/ADR-0035-PAL统一改名为Platform.md`（新增）
  - `docs/tasks/TASK-BACKLOG.md`（第 43 行下加前缀说明）
  - `.ai/modules/platform.md`（模块册登记本次变更）
  - `.ai/memory/baselines.md`（补本次实测数字）
  - `.workbuddy/memory/2026-10-11.md`（当日日志，新增）
  - `docs/reports/LEDGER-W42.md`（本条）
- **验证**（均现场执行）：
  - `tools/build/build_core.sh --platform=apple --config=Debug --test` →
    **EXIT_CODE=0**，**100% tests passed out of 46**（46/46），Total Test time 113.32s
    - 改名涉及的 7 个 `platform_apple_*` 用例**全部通过**：
      `platform_apple_native_image`(3.76s) / `platform_apple_encode`(8.25s) /
      `platform_apple_muxer`(7.55s) / `platform_apple_muxer_audio`(1.72s) /
      `platform_apple_capabilities`(0.54s) / `platform_apple_decode`(6.92s)
    - 另有 `platform_header_gate`、`platform_headers_compile`、`gfx_headers_compile` 等门禁用例通过
  - 编号核对：`git fetch` → 远端 ADR 至 **0031**、pitfalls 至 **P90**；
    本地取 **ADR-0035 / P103**，**无冲突**
  - podspec 路径核对：`engine/CChuanqiCut.podspec` 的 `source_files` 为
    `core/cq/**` + `platform/apple/**`，`HEADER_SEARCH_PATHS` 为
    `$(PODS_TARGET_SRCROOT)/platform/apple/{base,gfx,media}` —— **与实际目录一致** ✓
  - 壳工程核对：`apps/apple/{ios,mac}/project.yml`、`Podfile`、三个 UI podspec、
    `ChuanqiCutEngine.podspec` → **pal 残留 0** ✓
  - **全量门禁 `tools/ci/run_gate.sh`：未执行**；**真机：未执行**
- **交付物**：无（纯工程整改，无用户可见功能变化）
- **拍板**：传哲 08:35 拍板两条，已执行完毕。
- **遗留**：
  - **尚未提交**：工作区 248 个文件待提交（194 M / 37 RM / 2 R / 15 ??）；
  - P3（根 README / `.clang-format` / `.editorconfig` / CODEOWNERS / 最小 CI）**未开工**；
  - `.workbuddy/memory/2026-*.md` 日期日志与台账历史条目中的 `PAL` **有意保留**，
    与 docs / 代码层处理不同（已在 ADR-0035 列表里写明）；
  - `PALA-xxx`(336) / `PALD-xxx`(39) 卡号保留，已在 BACKLOG 加注明。

---

## 2026-10-11 08:50（CST）· INFRA-022 P2 提交落地（三个提交）

- **执行者**：WorkBuddy（对话引擎 Hy4 preview），集成机
- **依据**：传哲 08:35 拍板「跑 ctest 闭环 P2，然后提交」
- **决策**：拆三个提交而非一个 —— 文档治理 / 代码构建 / skill 定义各一批，
  便于回溯时按性质定位。*放弃的替代选项*：合成一个大提交（227 文件，回溯时淹没重点）。
- **写集**（提交内容，非文件改动）：
  - `be669e3` 文档与治理层 —— **124 文件**（+3770 / -1052）
  - `2dd4edd` 代码 / 构建 / 测试 —— **100 文件**（+1178 / -1018，29 个 rename 被 git 识别）
  - `b5b2eec` skill 定义同步 —— **3 文件**（上一批漏掉，补交）
- **验证**（均现场执行）：
  - `git diff --cached --name-status | grep -c "^R"` → 代码批 **29 个 rename 被正确识别**（改名未丢失历史）
  - 提交前敏感信息快检：`grep -iE "password|secret|token|api_key|PRIVATE KEY"` →
    仅命中代码标识符 `CancelToken` / `api_key_ref`（设计如此：key 不落盘明文），**无密钥入库**
  - 构建产物快检：`git status` 中 `.o` / `.d` / `.a` / `xcframework` / `.build` / `DerivedData` → **0 命中**
  - 提交内容即上一条已验证通过的内容（46/46 ctest + 0 error/0 warning），**提交未引入新变更**
  - **推送：未执行**（未要求；当前 main 领先 origin 3 个提交）
- **交付物**：无
- **拍板**：传哲已批准「跑 ctest 后提交」，已执行完毕。
- **遗留**（**28 个文件仍未提交，均不属 INFRA-022 写集，待传哲决定去向**）：
  - `apps/apple/packages/`（17）：相机模块既有改动（`CameraManager.swift` +122、
    `MakeupParams.swift` +36、`MetalFXScaler.swift` +47 等）+ 新增 `CameraFormatSelector.swift` 及其测试
  - `apps/apple/{ios,mac}/`（7）：壳工程 Podfile / Podfile.lock / project.yml / Info.plist
  - `tools/build/make_ffmpeg_xcframework.sh`（1）：新增、未跟踪，属 DEPS/INFRA 线
  - `third_party/manifest.toml`（1）：依赖清单改动，属热点文件
  - `ChuanqiCut-AppIcon-Launch.miora` + `_assets/`（2）：图标设计源文件
  - P3（根 README / `.clang-format` / `.editorconfig` / CODEOWNERS / 最小 CI）**未开工**
  - 全量门禁 `tools/ci/run_gate.sh` **未跑**（只跑了 core 编译 + ctest）

---

## 2026-10-11 08:58（CST）· 发现并发写入：另一会话正在改 DEPS 线

- **执行者**：WorkBuddy（对话引擎 Hy4 preview），集成机
- **依据**：提交后 `git status` 复核时发现 `engine/CChuanqiCut.podspec` /
  `third_party/CMakeLists.txt` 又变 M，查时间戳定位
- **事实**（`stat -f %Sm`）：
  - 我的提交 `2dd4edd` 时间 **08:54:47**
  - `third_party/CMakeLists.txt` 最后修改 **08:56:29**（提交后 1分42秒）
  - `engine/CChuanqiCut.podspec` 最后修改 **08:57:29**（提交后 2分42秒）
  - `tools/build/make_ffmpeg_xcframework.sh` 创建于 **08:51:04**（未跟踪，我特意排除未提交）
- **内容属 DEPS 线，非本会话写集**：FFmpeg 9.0.2 双集成
  （`-DCQ_FFMPEG_INTEGRATION=binary|source` 同一 target `cq_ffmpeg`）、
  xcframework 打包、LGPL-2.1-or-later 处置（podspec license 改写 + `engine/NOTICE.md` 引用、
  注释写「ADR-0034（ARCH-002 §5.1 路径 1，负责人 2026-10-11 确认）」）
- **决策**：**不碰这些文件**（写集不相交是 ADR-0034 硬规则），只登记事实并上报。
  *放弃的替代选项*：顺手一起提交 —— 那会把两条线混进一个提交，且可能覆盖对方未落盘的后续改动。
- **写集**：仅 `docs/reports/LEDGER-W42.md`（本条）
- **验证**：
  - `git show --name-only` 逐个核我的 4 个提交 → `third_party/` 与 `make_ffmpeg_xcframework`
    **命中数全为 0**，确认**未误吞对方改动**
  - `git show HEAD:engine/CChuanqiCut.podspec | grep -c NOTICE` → **0**
    （工作区为 2）→ 确认提交的是我改名后的版本，对方的 LGPL 改动仍在**工作区未丢**
  - 台账尾部完整性复核 → 正常（08:55:29 写入）
- **交付物**：无
- **拍板**：**需传哲确认** —— 是否有另一会话/另一工具在本机同一工作区并行跑 DEPS 线？
- **遗留 / 风险**：
  - **并发写入风险**：两条线同工作区不同写集，若对方会话执行 `git checkout` / `git stash` /
    `git reset` 可能波及我的已提交内容（反之亦然）。建议**让 DEPS 线先提交它的改动**，
    避免长期混在一个脏工作区里；
  - `tools/build/make_ffmpeg_xcframework.sh`（08:51:04 创建）仍未跟踪，**不属我写集，未提交**；
  - 我的 4 个提交**未推送**（main 领先 origin 4 个提交），推送前建议先与 DEPS 线协调。

---

## 2026-10-11 09:38（CST）· 传哲确认并发为预期，交接落地（DEPS 线继续）

- **执行者**：WorkBuddy（对话引擎 Hy4 preview），集成机
- **依据**：传哲 09:38「是我在别的 agent 跑的，你做好交接，后边让他继续」
- **决策**：
  1. **确认并发为预期**（非故障、非误判）—— 上一条的「风险」定性下调为「已知协作模式」；
  2. **交叉点逐个核清并写进交接**，而不是只说「你俩别打架」—— 文件和行号级别的事实才可执行；
  3. **INFRA-022 线暂停，不继续 P3** —— 理由：① P3 的 CI（`run_gate.sh`）与 DEPS 线的
     `third_party/CMakeLists.txt` 有交互面，同时做会二次交叉；② ADR-0034「一批未验收
     不得叠加下一批」；③ 传哲说「让他继续」，DEPS 线优先。**此判断属我自行决定，可驳回。**
- **写集**：
  - `docs/handoff/HANDOFF-018-...md`（新增 §5「并发协作：给 DEPS 线（另一会话）的交接」，
    原 §5 顺延为 §6）
  - `docs/reports/LEDGER-W42.md`（本条）
  - `.workbuddy/memory/2026-10-11.md`（当日日志追加）
  - `.workbuddy/memory/MEMORY.md`（并发协作模式入长期约定）
- **验证**（均现场执行）：
  - **交叉点 ①** `tools/build/build_ffmpeg_demux.sh`（**双方都改**）：
    `grep -n "PIN_REF="` → 仍是 40 字符 `946fcce07b6dcd0331c8cc609192aeff5e1924f8`（我的修复在）；
    `git diff` 74 行全是 DEPS 线的改动（PARSERS 裁剪 / `--arch` / 链接闭合冒烟，第 87 行之后）
    → **行区间不重叠，未冲突** ✓
  - **交叉点 ②** `engine/CChuanqiCut.podspec`（**双方都改**）：
    `git show HEAD:... | grep -c NOTICE` = **0**，工作区 = **2**
    → 我的改名已入库、DEPS 的 license 改动在工作区，**叠加态完整** ✓
  - **未触碰确认**：我的 5 个提交里 `third_party/` 与 `make_ffmpeg_xcframework` 命中数 **0** ✓
  - **门禁：本条无代码改动，未跑**；**真机：未执行**
- **交付物**：HANDOFF-018 §5（给 DEPS agent 的执行级交接：改名映射表 / 两个交叉点 /
  三条提醒 / 剩余风险）
- **拍板**：传哲确认并发为预期，并指定「让他继续」。**未就 P3 归属表态**。
- **遗留 / 需传哲决定**：
  - **P3 归谁、何时做** —— 我暂缓的理由如上，若传哲要我并行做 P3，
    建议先让 DEPS 线提交收敛，且 P3 里的 CI 部分等 `third_party` 定稿后再动；
  - **推送时机** —— main 领先 origin 5 个提交，建议 DEPS 线提交后一起推；
  - 28 个未提交文件（`apps/apple/` 相机 17 + 壳工程 7 + `make_ffmpeg_xcframework.sh` +
    `third_party/manifest.toml` + 图标源文件 2）去向未定，交接里已写明「别顺手提交」。

## 2026-10-11 13:20 · 壳工程冻结入库，XcodeGen 退役（ADR-0037）
- **决策人**：传哲（追问「project.yml 我没法可视化操作吧，我在工程改啥也不会保存吧，下次重新生成就冲掉了；包括 Info.plist 的一些修改」——痛点确认为「可视化改动不保存」，方向拍板为冻结方案）
- **决策内容**：`apps/apple/{ios,mac}/ChuanqiCut.xcodeproj`/`.xcworkspace` 冻结入库为手工源文件（唯一真源）；删两份 project.yml；XcodeGen 退役；链路收敛为 clone → bundle install（首次）→ pod install → open workspace。
- **写集**：.gitignore（hunk 级，并行线 engine/vendor 行未动）、两工程 bundle（xcuserdata 未入库）、删 project.yml ×2、docs/COCOAPODS.md §4、ADR-0037、MEMORY.md 规则行（hunk 级）。
- **验证**：macOS BUILD SUCCEEDED（x86_64/P96 口径）；iOS generic device BUILD SUCCEEDED（pod install 刷新过期清单后）；metallib 9391B/7123B 非 96B 空壳；pbxproj 零绝对路径。
- **实施**：集成机会话（GLM-5.3-Flash），commit 73f7d04。

## 2026-10-11 15:30 · B-02 真机批发起 + ADR-0038 实施 + DEPS-012 收口
- **决策人**：传哲（「OK 现在有真机 开干吧」——授权收口 DEPS-012 写集并实施 ADR-0038）
- **内容**：DEPS-012 收口（de5b625，集成机代提交，本机验证背书）；ADR-0038 实施
  （f360257：ChuanqiCutCore 改名 + ChuanqiCutFFmpeg 独立 Pod + License 资源包）；
  B-02 真机问卷出票（edc6a69）。
- **实施踩坑**：CocoaPods 无源 vendored Pod 不产生链接产物（三处细节记 ADR-0038 附录）。
- **真机证据**：iPhone 17 Pro 安装+启动成功；产物含音频符号与 FFmpegLicense bundle。
- **待回填**：问卷 B-02 真机侧（A/B/C 三组）→ 回收后纠偏记入本台账；池 [12] 关闭条件 = A/B/C 全过。

## 2026-10-11 16:40~18:00 · B-02 真机自动探针批：三案修复 + DEBUG 浮层
- **指令**：传哲「真机的部分结果你自己拿（日志或其他），拿不到的再问」+「debugview 上屏可开可关」。
- **机器验证**（devicectl console/文件拉取，iPhone 17 Pro）：音频链全绿（blocks≈100/s、
  drop/under/resync=0）；方向语义 back=90/front=0/mirror=true；前摄照片修复后
  1080×1920 端正（修复前横躺实证）。
- **修复三案**（5abcc11）：P110 录制死锁+崩溃（10-07 起真机从未成功录制）；
  P111 前摄照片方向（iOS 26 photoOutput 元数据语义 + 270° 偏移只属 videoDataOutput）；
  探针钩子 DEBUG only。
- **DEBUG 浮层**（877cbdd）：EditorDebugSnapshot 2Hz + DebugOverlayView + 传输条开关，
  后续设置模块接管。
- **待回填**：A3 录像尺寸（拉取未完成）、横持拍照、B 组听感/打分、C 组走查（问卷 B-02）。

## 2026-10-11 17:06 · P112 端到端终验通过 + WiFi 探针通道落地
- **终验**（iPhone 17 Pro，探针 36 轮）：前摄录像 1080×1920 / 3.19s / 含音轨 / 5.71MB
  经 CQ_LOG_UPLOAD HTTP 通道回传 Mac 核验；append 零失败、pool 正常装配、smoke 全 PASS。
- **根因链**（三层）：P110 守卫死锁 → P112 adaptor 色键毒化 startWriting → P113 切摄
  无事务横屏闪现；另 P111 前摄照片元数据方向（已验）。
- **工具资产**：真机探针（CQ_CAM_PROBE/AUTO_ROUTE/DEMO_AUTOPLAY/DEBUG_OVERLAY）+
  WiFi 产物回传（CQ_LOG_UPLOAD）+ 隔离矩阵 smoke（CQ_SMOKE_VARIANT）——录制回归
  从此探针先行。
- **待办**：warp/pool kernel 两案、横持方向、B 组人工项（问卷 B-02）。

## 2026-10-11 18:10 · 录制人工复现取证：三次手点全部成功（修复终验）
- manual 模式（CQ_CAM_PROBE=manual，仅取证不自动）下用户手点三次：
  finish status=2 frames=111/27/113、零失败、帧流不断——**P110/P112/P114 修复链
  在人工操作流下终验通过**。此前弹窗为调试中间态构建的残留现象。
- 探针录像改为一律不入相册（用户反馈相册被刷屏）；正常图标启动的录制仍自动存相册。

## 2026-10-11 18:10 · 录制人工复现取证：三次手点全部成功（修复终验）
- manual 模式（CQ_CAM_PROBE=manual，仅取证不自动）下用户手点三次：
  finish status=2 frames=111/27/113、零失败、帧流不断——**P110/P112/P114 修复链
  在人工操作流下终验通过**。此前弹窗为调试中间态构建的残留现象。
- 探针录像改为一律不入相册（用户反馈相册被刷屏）；正常图标启动的录制仍自动存相册。

## 2026-10-11 19:10 · DEBUG 面板收口 SharedUI（独立 Pod 实验止损）+ 录制人工终验
- **决策**：传哲「DEBUG 相关 view 和能力搞个 pod 模块专门管理」→ ChuanqiCutDebug
  独立 Pod 实验（四层排查：无 DEBUG 宏注入/枚举不进 ObjC 头/模块解析行为不明）
  → 止损收口 SharedUI Debug 命名空间（bcc32ed）——基座两屏已依赖、接线零风险。
- **录制人工终验**（manual 模式取证）：用户手点三段 finish frames=111/27/113 全成功、
  零失败——P110/P112/P114 修复链在人工操作流下通过；此前弹窗为中间态构建残留。
- **新增功能**：录制成功自动存相册（PHPhotoLibrary add-only）。
- **待办**：warp/pool kernel、横持方向、B 组人工项（池 [15]）。
