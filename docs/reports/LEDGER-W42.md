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

## 2026-10-11 19:50 · 相机右侧边栏（对标平台式）+ 全局 DebugCenter + 浮层拖拽滚动
- **指令**：传哲四条——操作按钮右侧边栏 / debugview 左侧可滚动 / 位置可拖动 /
  DEBUG 全局存在（内存/CPU 实时）。
- **实现**（59aa2b6）：相机页操作按钮（美颜/设置/双摄/翻转）收进右缘纵向边栏；
  DEBUG 浮层左侧默认、Grabber 手柄拖动（偏移 UserDefaults 按屏持久化、双击回位）、
  内容可滚动；SharedUI 新增 DebugCenter（全局开关持久化跨屏共享 + 2Hz 系统采样：
  phys_footprint 内存 + TASK_THREADS_INFO 差分 CPU%）。
- **坑**：Mach 的 TASK_THREADS_INFO 不在 iOS SDK 用户态头（编译错）→ 换
  task_threads() 枚举 + 逐线程 THREAD_BASIC_INFO；SharedUI pod 的 swiftmodule
  曾整模块丢失（CocoaPods 无 DEBUG 宏注入 + 条件编译包裹 → 已去条件编译）。
- **验证**：iOS 全量构建 SUCCEEDED；探针 smoke PASS；浮层拖拽/滚动/全局开关为
  视觉组件待传哲目检。

## 2026-10-12 12:10 · 真机日志纠偏三案（导入 967ms / 美型跳过 / drawable 崩溃）

> 决策与实现者：集成机（WorkBuddy，Claude）· 2026-10-12 · 传哲回传真机日志后拍板「继续吧」→
> 指定**跑全量 `run_gate.sh`**（2026-10-12 11:43）。

### 输入（传哲真机日志，2026-10-12 回传）
1. `[import] probe 970ms` + `WARN 慢调用 demuxer Open(含 ScanKeyframes) took 967ms`
   + Thread Performance Checker「User-interactive 等 Default QoS」—— 主线程阻塞 ~1s。
2. `Warp kernel function 'cq_face_warp' does not have a coreimage:destination argument`
   → `warp engine FALLBACK` —— **美型一直静默跳过**（CAM-033 只修了 sampler，没修 destination）。
3. 长跑后 3 次 `MTLTextureDescriptor has invalid pixelFormat (0)` 断言 →
   `Debug session ended with code 9`（signal 9 = jetsam SIGKILL）。
4. 播放段 footprint 188.0→200.2→251.9→263.9→282.4MB（t=2→10s，1080×1920）。

### 决策
- **P122**：Platform 工厂不是零成本构造 —— `CreateMediaDemuxer` 内部就全量 Open，
  MEDIA-026 的 OpenLight 优化被工厂吃掉。「轻量」必须在**工厂层**分叉，不能只在实例方法层。
- **P123**：CIWarpKernel 首参必须 `coreimage::destination`，裸 `float2` 没有 coreimage 标记。
- **P124**：drawable 的格式/尺寸是不可信输入；signal 9 先怀疑 jetsam，Metal 断言常是下游症状。
- **不做的**：①导入链路异步化（要动 @MainActor 边界，单独建卡）；②临时内存埋点
  （先用 Xcode Memory Graph 取证，取证前不改代码）；③PHAsset 元数据后台化（池 [17]）。

### 写集（7 文件）
- `engine/core/cq/platform/chq_media.h`（+`CreateMediaDemuxerLight` 声明）
- `engine/platform/apple/media/media_demux.mm`（+轻量工厂实现）
- `engine/core/cq/media/chq_media_probe_abi.cpp`（改用轻量工厂，去掉多余的 OpenLight 调用）
- `tests/unit/test_media_demux_apple.cpp`（+4 断言：时长与全量一致 / GetStreamCount==0 /
  不可读包 / 工厂成功）
- `apps/apple/packages/ChuanqiCutCamera/.../Effects/face_warp.metal`（首参 → `coreimage::destination`）
- `apps/apple/packages/ChuanqiCutCamera/.../Effects/FaceWarp.swift`（注释补契约）
- `apps/apple/packages/ChuanqiCutCamera/.../CameraRenderer.swift`（drawable 退化校验 + error 留痕）

### 验证（本机实测，Intel x86_64 / macOS 26.7.1 / Xcode 26.6）
- `bash tools/ci/run_gate.sh`：**PASS=14 FAIL=0 SKIP=0**（22m14s）。
  core-dbg **48/48**、core-rel **48/48**；apple-swift-bindings 26、camera 77、import 16、
  editor 65、player 52，**全部 0 failure**；deps/headers/artifacts/golden 均 PASS。
- 新增 4 项断言随 `platform_apple_demux`（Test #28）Passed 通过。
- **未验**：`face_warp.metal` 的 `-fcikernel` 编译**不在门禁内**（门禁无 iOS 壳构建步骤），
  已单独补跑 `-scheme ChuanqiCutApp -destination generic/platform=iOS`（结果见下条）。

### 拍板/待回收
- 传哲拍板：跑全量门禁（已跑，绿）。
- 问卷 `docs/reviews/QUESTIONNAIRE-2026-10-12-真机批-日志纠偏三案.md` 已出，**未回收不得标记完成**。

---

## 2026-10-12 19:08｜周报 W42 出刊（集成机，本机）

### 决策
- 传哲要求出周报，内容扩到七块：整体项目 / 技术细节 / Pipeline / 当前实现优缺点 /
  未来优化路径 / 分工与进展 / 下周计划。本机（集成机）出刊，落 `docs/reports/WEEKLY-2026-W42.md`。
- 覆盖窗口定为 **2026-10-08 ~ 10-12**：W41 周报正文只写到 10-07，10-08~10-11 无周报覆盖。
- **口径决定**：周报里「已实现 vs 规划中」必须分项写死 —— 明确写「**现在还不能导出成片**
  （`cq_sdk.h` 无 `cq_export*`）」「RenderGraph 未开工」「SPIR-V 链零文件」，
  不因门禁 PASS=14 而把愿景写成现状（呼应 P99「绿而空」）。
- 分工按四条线报（集成机 / A 编辑·AI / B 相机 / C 内核媒体渲染），不按机器报 ——
  本机同工作区多 agent 并行已是常态，机器口径会误导。

### 写集
- `docs/reports/WEEKLY-2026-W42.md`（新增）
- `docs/README.md`（§6 周报表补 W42 索引行）
- 本文件（append）

### 验证
- 数字全部来自既有实测（门禁 / baselines / 台账 / 模块册），**本轮未新跑门禁**。
- 引用前逐条区分实测 vs [E] vs hypothesis；`baselines.md` 的 PERF-001 未建已在周报里明写。
- 已知文档漂移（已写进周报 §5.2）：RESEARCH-010 缺口清单 4 条已被 10-11/10-12 提交推翻但未回填；
  `docs/api/engine-api.md` 生成源路径失效且缺 6 个新函数；TASK-CAM-034/035 卡片状态未回填。

### 拍板/待回收
- 无新拍板（本周报不含代码改动）。
- 下周三项待传哲拍板已写进周报 §9：①B0（RENDER-001）范围 + shader spike ②池 [18] 门禁加壳
  ③池 [17] 内存取证方式（取证前不改代码）。

---

## 2026-10-12 21:55｜B0 渲染地基三块落地（RENDER-001 + SHADER-001 + MODEL-003）（集成机，本机）

### 决策
- 传哲拍板 B0 开工，授权「该写的代码一口气写出来，然后统一跑真机」；音频/视频/渲染多线并行。
- **RENDER-001**：取 Pull（与泵线程请求驱动逐该厂商一致，保「与原 blit 路径像素一致」出口）；
  装配器三图同源（kPreview/kExport/kAudioOnly，红线 #9 的可执行形式）；B0 只装配命中轨，
  多轨命中 Warn + 只取第一条；节点上限 32 / 输入上限 4（B0 图固定 3 节点）。
- **SHADER-001**：双层链 Portable GLSL 450 → glslang(SPIR-V) → SPIRV-Cross(MSL) → 构建期拼
  `blit_msl.h`；工具链（glslang 16.0.0 / SPIRV-Cross）scope=build、产物不入库。
- **MODEL-003**：效果即数据（ChqPropertyValue/Bag + ChqEffectBinding/Stack 挂 ChqClip）；
  属性袋用 std::map 保序（指纹与插入序无关，unordered_map 会漂）；
  **标量用 float 不用 double**（契约头门禁禁 double token，与 chq_gfx.h clear_color 先例一致）；
  **时间不进属性**（红线 #4 的前提，属性只装图形参数）；属性变更一律走 Command（红线 #5），
  四条新命令；「新建参数」的撤销走擦除而非写假默认值（不留幽灵参数）。
- **效果应用不进 B0**：装配器对带**启用**效果的片段如实上报 effects_dropped（Warn，
  Release 可见），消费归 RENDER-011（B7）—— 不许「加了却没效果」的静默失败。
- **壳工程接线补齐（集成机职责）**：shader agent 只接了 CMake 侧（custom command），
  Pods/Xcode 侧零接线 → 壳工程会直接编不过 `blit_msl.h`。本机在 podspec 声明
  `script_phases`（before_compile）+ HEADER_SEARCH_PATHS 补生成目录，两套构建系统
  写同一份幂等产物（仓库根 build/generated/shaders/）。**不许为壳工程回退成手写 MSL**
  （那正是 ADR-0014 两套路径的复刻）。

### 写集（本批；与 DEPS-012 / 其它线无交叠）
- 新增：`engine/core/cq/render/`（clock_source / render_graph / graph_assembler /
  render_evaluator / fit_mode / fit_viewport / frame_source，7 头 + 4 实现）、
  `engine/core/cq/model/chq_property.{h,cpp}`、`shaders/src/blit.{vert,frag}`、
  `tools/shaders/build_shaders.py`、`tests/unit/test_render_graph.cpp`、
  `tests/unit/test_model_property.cpp`、`tests/unit/test_c_abi_property.c`
- 修改：`chq_timeline.{h,cpp}`（ChqClip 挂效果栈 + 7 个效果方法）、`chq_command.{h,cpp}`
  （4 条属性命令）、`chq_editor_model_state.cpp`（digest 混入效果栈指纹）、
  `chq_editor_session.{h,cpp}`（4 个 Submit*）、`cq_sdk.{h,cpp}`（11 个 ABI 函数 +
  2 个查询结构体）、`chq_preview_renderer.{h,cpp}`（改走 RenderGraph）、
  `engine/platform/apple/gfx/blit_pass.mm`（消费生成 MSL）、
  `engine/platform/apple/CMakeLists.txt`、`engine/ChuanqiCutCore.podspec`
  （script_phases + header search path）、`engine/core/CMakeLists.txt`、
  `tests/CMakeLists.txt`、`tests/unit/test_model_command.cpp`（本地指纹覆盖 effects）

### 验证（本机实测，Intel x86_64 / macOS 26.7.1 / Xcode 26.6 / Swift 6.3.3）
- `tools/build/build_core.sh --platform=apple --config=Debug`：**0 error / 0 warning**（-Werror）；
  `--config=Release` 同（Release 是发布必经路径，两边都跑）。
- `ctest --test-dir build`：**Debug 51/51 Passed**（76.8s）、**Release 51/51 Passed**（74.9s）。
  批前基线 48；本批 +render_graph(49) +model_property +c_abi_property。
- 新用例断言数：`model_property` **179 checks 0 failures**；`c_abi_property` **76 checks 0 failures**；
  `render_graph` 全过（含新增的 effects_dropped 两例）；`preview_renderer` 51 项全过
  （RenderGraph 接入后像素一致：contain 清屏黑 / 真值像素保持）。
- `platform_header_gate` PASS（新模型头的 float 用法合规，未触发 double 规则）。
- SHADER-001 链通：glslang -V --target-env vulkan1.1 → spirv-cross --msl →
  `xcrun -sdk macosx metal -c` rc=0（spike 时实测）。
- **未跑/未收**：全量 `run_gate.sh`（须传哲同意，未跑）；iOS 壳构建进行中（见下）；
  macOS 壳构建未跑；真机问卷未出未收。**B0 不得标记完成**（问卷未回收）。

### 拍板/待回收
- 传哲拍板：B0 开工 + 「一口气写代码后统一跑真机」（授权在；真机部分未执行）。
- 音频线（AUDIO-004 多轨 PCM 混音）agent 因 **429 限流失败**（重置 2026-10-13 10:38 UTC+8），
  **未产出任何代码** —— 待限流恢复后重派，或由集成机串行补写。
- 视频线未定卡：候选 FFmpegFrameProvider（与 DEPS-012 线交叠）或导出编排器；
  按 ADR-0034「一批未验收不得叠加」，待 B0 真机问卷回收后再开。
- 两个技术待答复（不阻塞本批）：①build_shaders.py 的 Python3 依赖（CMake 侧已
  find_package(Python3)，Xcode 侧用系统 python3）；②UI 侧 PreviewFrameRenderer.swift
  手写 MSL 是否并入 Portable 链（建议不在本批动，先登记）。

### 补记（2026-10-12 22:50，同批追加，append-only 不改上文）
- 壳构建补齐（承接上条「iOS 壳构建进行中」）：`pod install`（iOS + mac 两端）后
  **iOS `ChuanqiCutApp` generic/platform=iOS：BUILD SUCCEEDED**（1m14s）；
  **macOS `ChuanqiCutMacApp -arch x86_64 ONLY_ACTIVE_ARCH=YES：BUILD SUCCEEDED**（48s）。
  podspec script phase 两端实际执行（Xcode 警告可见），`blit_msl.h` 生成后被找到。
- Mac 侧首次构建失败一次：起跑早于 mac `pod install` 完成（Pods 工程还是旧清单，
  blit_pass.mm 编不过）—— 刷新后即绿。**教训固化：podspec 增删文件/改 script phase 后，
  两端都必须重跑 `bundle exec pod install` 再构建，顺序不能反。**
- 真机问卷已出：`docs/reviews/QUESTIONNAIRE-B0-B0渲染地基三块.md`（未回收）。

### 补记二（2026-10-12 收工复核，同批追加，append-only 不改上文）
- **数字复跑（本机 Intel x86_64，无新代码变更，仅文档）**：`ctest` Debug
  **51/51 Passed（100%，75.57s）**；`cq_tests_model_property` **179 checks / 0 failures**；
  `cq_tests_c_abi_property` **76 checks / 0 failures**。与 22:30 段一致。
- 模块册注记落点修正：`.ai/modules/shader.md`「落地状态」块从标题后移到归属行之后
  （render.md / model.md 落点本就正确）。
- 新增 pitfalls **P125**：podspec 加 `script_phases` 不重跑 pod install = 生成头缺失，
  报错点骗人（.mm include 行）；规则 = podspec 任何改动必须双端 pod install。
- 两个技术待答复的**结论**（不再挂起）：
  ① build_shaders.py 纯标准库；CMake 用 `Python3_EXECUTABLE`、podspec 用 PATH
     `python3`；真正硬依赖是 `build/tools/{glslang,spirv-cross}`（tools/deps 产物、
     不入库）→ 新克隆机必须**先 tools/deps 再 pod install / 构建 core**，否则脚本
     以可读诊断退出（不静默假绿）。
  ② UI 侧 `PreviewFrameRenderer.swift` 手写 MSL **不并入** Portable 链（本批决策：
     UI 包耦合 engine 构建产物属新架构问题，按「一批未验收不叠加」不夹带）；
     已把该文件头注释改准（指向 `blit_pass.mm` 的 `kBlitVerts` + SHADER-001 链），
     并如实写明"UI 呈现 shader 仍是手写平台原生版本"。是否让 UI 消费引擎生成的
     MSL 留待传哲拍板。

### 补记三（2026-10-13 13:xx，AUDIO-004 编码轮，append-only 不改上文）
- **AUDIO-004 开工（传哲 12:52 授权「音频线跑起来吧」；429 重置 10:38 已过）**。
  scope 裁决：只做混音原语（`chq_mix.{h,cpp}` 的 `MixAccumulateRange` 增益累加 +
  `MixClipRange` 硬削波，非有限值按 0）+ 预览混音器改用它，**不做** AudioGraph 多输入
  扩展 / 母带限制器 / solo / 非 float32 总线 / dB 换算 / 模型音量字段（理由见卡）。
- **消灭并行实现**：预览混音器内联求和 + 削波已删，改调 `chq_mix.h` 原语（ADR-0014 教训）。
  增益取点以 `kTrackGainUnity` 命名常量留出（模型无音量字段前恒 1.0）。
- **实测（本机 Intel x86_64）**：`build_core.sh` Debug/Release 各 **0 error 0 warning（-Werror）**；
  `ctest` Debug **52/52**（批前 B0 基线 51，+core_audio_mix）；`ctest -R audio` 两端各 **5/5**；
  `core_audio_mix` **57 检查 0 失败**；平台头门禁 43 头 0 违规。
- **未做**：全量 `run_gate.sh` 未跑（须传哲同意）；音频无真机可听感验收路径（PALA-030 未做）
  → **不出音频真机问卷**；AUDIO-004 不标记完成（等 B0 问卷回收 + 全量门禁后再并批）。
- **写集不相交核验**：AUDIO-004 写集（chq_mix.* / 预览混音器 cpp / 双 CMake / 单测）与 B0 批
  （model_property / cq_sdk 等）只在 `engine/core/CMakeLists.txt`、`tests/CMakeLists.txt`
  两个热点文件交叠 → 由集成机串行改、改完即构建验证（已做），未动 B0 已落文件一字。
- **全部改动未提交 git**（与 B0 批同池，合并快检须传哲同意）。

### 补记四（2026-10-13 20:1x，RESEARCH-016 调研 + B0 提交 + B5.5 排期重构，append-only 不改上文）

**① RESEARCH-016 交付（传哲发起「看下对标平台的设计思路」）**
- 材料 `/Users/zhuning/Documents/test/`（7 模块 / 1335 头 / 78808 行，**只有头文件无 .m**）
  → 结论全部由声明推断，运行时/性能一律标 hypothesis。4 路并行探索 + 本人逐条实测复核。
- 产出 `docs/research/RESEARCH-016-对标平台编辑SDK架构逆向与借鉴评估.md`。

**② 传哲三项拍板（2026-10-13，AskUserQuestion 三问全选推荐项）**
1. B0 的 53 项未提交改动 → **现在提交**（授权我跑合并快检）；
2. B0 真机问卷（8 检查点）→ **传哲近期跑真机填**；
3. 新地基批次位置 → **B4 之后、B6/B7 之前**。

**③ B0 提交（合并快检后）** commit `2e8b55d`，工作区归零。
- `build_core.sh --platform=apple Debug`：PASS（**3m49s**，0 error / 0 warning，-Werror）
- `ctest`：Debug **52/52 Passed**（78.66s；B0 问卷记录为 51，+core_audio_mix）
- 冲突标记扫描 **0**；PAL 旧名残留 **0**（`core/src/` 仅出现在历史调研文档描述中，非写集路径）
- SharedUI `swift test`：编译 PASS（3.36s），**该包无 Tests 目标**（`no tests found`，非失败，
  已如实记为"窄检退化为编译验证"）
- **未跑**：全量 `run_gate.sh`（未申请）、真机（问卷交付传哲）、`golden verify.py`（本批不产帧）
- 状态：B0 **已提交但未标记完成**（问卷未回收，ADR-0034）。

**④ 排期重构：ADR-0040 新增 B5.5「空间与交互地基」**
- 依据：RESEARCH-016 §2.3 比对出 `ChqClip`（`chq_timeline.h:44-62`）缺
  transform / layer / speed / keyframes / relative 布局 / audioFilter，
  而 RESEARCH-010 原批次表**无任何一批为这些数据立地基** —— 照原排期到 B7 才补，
  会重演 ADR-0014 返工。
- 位置：B4 之后、B6 之前（**第一个可见出口不推迟**；仍在依赖它的 B6/B7 之前立住）。
- 立卡：`TASK-MODEL-004`（ChqTransform + layer + speed + keyframes 数据槽）、
  `TASK-EDIT-012`（commit/done 双层 PreviewSync 通道）。
- 修订：`RESEARCH-010` §5.2 批次表 + §5.3 拓扑已更新（B6/B7 自此可并行，B8 仍串在 B7 后）。
- 连带决策：**B3 持久化建议排到 B5.5 之后**（否则序列化要改两遍；若提前做必须可扩展）。
- **明确不采纳**（对标平台做法，逐条理由见 ADR-0040 §5）：整模型快照 undo、双数据模型、
  预览/导出两条管线（**本仓红线 #9 更先进，不动摇**）、浮点秒、标量 BOOL 表达状态机。

**⑤ 开工顺序（按 ADR-0034「一批未验收不叠加」）**
- B0 问卷回收 → 方可开 B4；B5.5 在 B4 之后。
- 当前**不**在 B0 之上叠加任何批次。

---

## 补记五：UIA-041 U0（轨道交互收敛）—— 2026-10-13 夜，WorkBuddy（集成机）

**传哲拍板**（本轮选项 A）：直接开 UIA-041（U0 交互收敛 + U1 视觉保真）。
立项前提：U 线写集仅 `apps/apple/packages/ChuanqiCutEditor/**`，与 B0 的 `engine/**` 不相交，
故不违反 ADR-0034「一批未验收不叠加」，B0 问卷未回收也可并行。

### 1. 开工前的自查纠错（先纠错，后动手）

- **纠 RESEARCH-017 §2 S3 行的误判**：初版写「S3 选中态视觉 ❌ 无选中视觉层
  （grep selected/handle 零命中）」。实为 **P126 ripgrep `\|` 字面量导致的假阴性** ——
  白描边两侧均有实现（`TimelineContentView.applySelectionBorder` L330-340 /
  `EditorTimelineView.draw` L362-372，均为 `Theme.primaryText`=白 lineWidth 2）。
  真正缺的只有**左右把手 + 片段中央时长数字**。已留痕更正 RESEARCH-017 §2 与 §6。
- **P128**：本会话模型不支持读图（6 张对标 App截图未实际看到），规格为转述，已在坑册登记。

### 2. 事实：双份实现消除（可机器复核）

新增 `Sources/ChuanqiCutEditor/TrackInteraction.swift`（reducer 域，不 import SwiftUI/UIKit）：
`TrackGestureEvent` / `TrackIntent` / `TrackClipEdit` / `TrackInteractionState` /
`TrackRenderState` / `TrackInteraction`（reduce + renderState + ownsPan + scrubSeconds）/
`TrackIntentApplier`（Intent→VM，全仓一份）。

验收核验（`/usr/bin/grep -nE`，且用 python 逐行扫交叉复核 -P126 后不该再信单次 grep）：

| 对象 | 命中判定 hitTest | 命令调用 moveClip/trimClip/… | projectTimescale 换算 |
|---|---|---|---|
| `EditorTimelineView.swift`（SwiftUI） | 无 | 无 | 仅 scrub→setPlayhead |
| `UIKit/EditorTimelineUIView.swift` | 无 | 无 | 无 |
| `UIKit/EditorViewController.swift` | 无 | 无 | 仅 scrub→setPlayhead |
| **`TrackInteraction.swift`** | **全部在此** | **全部在此** | **编辑换算全部在此** |

残留的两点（**不是重复，已核**）：①`ClipDrag` 定义体仍在 View 文件里（历史遗留，
本批刻意不搬家，避免 diff 混批，已在代码注释标 TODO）；②两侧各留 scrub→setPlayhead
的数行（平台原生滚动差异，见 TrackInteraction 文件头「刻意不收敛」一节）。

### 3. 收敛中修掉的两处双实现行为分歧（这是 U0 的实际收益，务必留痕）

| # | 分歧 | 修前 | 修后 | 证明用例 |
|---|---|---|---|---|
| ① | 零位移是否提交 | UIKit 有 `>1e-9` 守卫；**SwiftUI 无条件提交** → 撤销栈不一致 | 统一不提交（在 reducer 里） | `testZeroDeltaDragEmitsNothing` |
| ② | 末次位移取哪个 | UIKit 沿用最后 changed；SwiftUI 用 ended 重算 → 快甩落到不同帧 | 统一以 ended 的累计位移为准 | `testDragEndedUsesFinalTranslation` |

另：`testCrossTrackWithoutHorizontalDeltaStillCommits` 钉住「纯跨轨也必须提交」
（水平 zero 但轨道变了，`shouldCommit` 的 `||` 语义，防止以后误改回 `&&` 丢操作）。

### 4. 数字（本机：macOS 26.7.1 / Xcode 26.6 / Intel x86_64；2026-10-13 实测）

- `swift build --disable-sandbox`：**Build complete，0 error 0 warning**
- `swift test --disable-sandbox`：**Executed 81 tests, 0 failures**（8.5s）
  —— 基线 65 → 81：**新增 16**（`TrackInteractionReducerTests`）
- 新增测试文件：`Tests/ChuanqiCutEditorTests/TrackInteractionReducerTests.swift`
  （16 用例：tap / drag 生命周期 / 跨轨 / 渲染态派生 / ownsPan / scrub 数学）

### 5. 状态

- U0 **代码完成 + 机器自证完成**；UIA-041 整体**未标记完成**（U1 未做完 + 问卷未回收）。
- **未跑**：全量 `run_gate.sh`（未申请）、iOS 壳构建（UI 批的必跑项，见记忆 #18 缺口）、真机问卷。
- 待办（不丢）：`ClipDrag` 搬进 TrackInteraction 域；U1 视觉保真；UI 批的 iOS 壳构建。

### 6. 顺带登记的环境事实（已写入 pitfalls）

- **P126 更正**：本机 shell 的 `grep` 是 **toybox 0.8.13**（非 BSD），**不支持 `\|`**，
  一律用 `grep -E`。此前「BSD grep 支持 \|」的实测结论**是错的**（实验无区分力）。
- 本晚 P126 复发 2 次（RESEARCH-017 定稿时 + U0 验收核验时），均靠「换写法复核」捞出。

---

## 补记六：UIA-041 U1（轨道区视觉保真）+ 壳构建收紧 —— 2026-10-13 深夜，WorkBuddy（集成机）

### 1. U1 落地项（对照 RESEARCH-017 S1~S4/S7/S11，两侧同形态）

新增 `Sources/ChuanqiCutEditor/TimelinePalette.swift`（**分域色表**）：
- **不越界改 SharedUI/Theme**（写集约束，ADR-0034）。`Theme.playhead` 仍是红色由轨道区之外的消费者继续用；
  轨道区自本批起用 `TimelinePalette.playhead`（白）。TODO 已写：二选一后整表迁移，不许长期两套并存。
- **不 import SwiftUI/UIKit 存储**，只依赖 CoreGraphics；`RGBA` 同时提供 `.cgColor`（CALayer）与
  `.uiColor`（UIView.backgroundColor）/ `.color`（SwiftUI）—— **一处 RGB，三种取法**，不许抄两份。

| 规格 | SwiftUI 侧 | UIKit 侧 |
|---|---|---|
| S3 选中：白描边（**已有，非新增**）+ 左右把手 + 中央时长数字 | `drawSelectionChrome` | `applySelectionChrome` + `selectionChromeLayers` |
| S4 播放头红→白 + 顶部小把手 | `draw` | `playheadOverlay` + `playheadKnob` |
| S1 刻度主/次 + 圆点分隔 | `draw`（消费 `layout.styledRulerTicks()`） | `rebuild`（同） |
| S7 主轨右端「+」 | **未做**（本批 Scope 见下 §4） | `addButton` + `onRequestAppend` → `onOpenMedia()` |
| S11 预览选中红框 | `PreviewZone.isClipSelected` | `previewSelectionBorder` |
| S2 轨道头（原声状态） | **未做** | `buildTrackHeaders`（**disabled 只读态**） |

共享纯函数下沉：`TimelineLayout.styledRulerTicks()/rulerStepSeconds`
（主次判定与「下一个主刻度在哪」属几何知识，两展示层不再各解一遍元组）。

### 2. 坦白项（不藏）

- **S2 轨道头只能显示不能点**：内核**没有写 `muted` 的 ABI**
  （`CQTrackInfo.muted` 经 `cq_sdk.cpp:488` 单向填出；全仓无 `cq_session_set_track_muted`）。
  按任务卡「不做假开关」做成 disabled 只读态，显示**真实回读值**。欠账 → **池 [19]**。
- **S7 只做了 UIKit 侧**，SwiftUI 侧（`EditorTimelineView`）未加「+」 —— 本批未铺满，记 §4。
- 我**没看到那 6 张截图**（P128）：所有尺寸/配色是 [E]，以 §3 问卷回收校准为准。

### 3. 数字（本机 macOS 26.7.1 / Xcode 26.6 / Intel x86_64；2026-10-13 实测，**全部为真实命令输出**）

| 验证项 | 命令 | 结果 |
|---|---|---|
| 包编译 | `swift build --disable-sandbox` | Build complete（**⚠️ 不算证据，见 §5**） |
| 包测试 | `swift test --disable-sandbox` | **Executed 81 tests, 0 failures**（8.9s） |
| **iOS 壳构建** | `xcodebuild -workspace apps/apple/ios/ChuanqiCut.xcworkspace -scheme ChuanqiCutApp -destination generic/platform=iOS build` | **BUILD SUCCEEDED** |
| **macOS 壳构建** | `cd apps/apple/mac && xcodebuild -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutMacApp -arch x86_64 ONLY_ACTIVE_ARCH=YES build` | **BUILD SUCCEEDED**|
| 全量门禁 | `run_gate.sh` | **未跑**（未申请） |

### 4. 状态与剩余

- UIA-041 = U0 ✅ + U1 **部分**（SwiftUI 侧缺 S7「+」与 S2 轨道头）。
  卡面状态写「📋 未标记完成」，原因：U1 未铺满 + **问卷未回收**（ADR-0034）。
- 未做/待办（均已在卡面或池里挂号，不丢）：
  SwiftUI 侧 S7「+」与 S2 轨道头；`ClipDrag` 搬进 TrackInteraction 域；U2 起的信息架构批。

### 5. 本批最有价值的工程教训 → **P129**（已入坑册）

**`swift build/test` 报全绿，但 `#if os(iOS)` 里的文件在 macOS 上根本没被编译。**
UIKit 侧改完一遍，`swift build` 全程 "Build complete"；iOS 壳构建一把抖出 10 个错误
（CGColor≠UIColor、成员加错类、`CATextLayer.string` 是 `Any?`、`CGPoint`≠`CGSize`、
Pods 清单过期）。连带两条：**iOS/mac 是两个独立 Pods 工程，podspec 文件变动要两端各
`bundle exec pod install` 一次**（本次 mac 端漏跑就报 `cannot find 'TimelinePalette' in scope`）；
macOS 壳 destination 的可用写法是**不带 destination** 的 `-arch x86_64 ONLY_ACTIVE_ARCH=YES`。

**这条改变了以后 UI 批的最小自证口径**：Apple 端 UI 改动，`swift test` 数字**不能替代**两端壳构建。

### 6. 本批交付物

- 代码（写集 `apps/apple/packages/ChuanqiCutEditor/**`)：`TrackInteraction.swift`(新)、
  `TimelinePalette.swift`(新)、`EditorTimelineView.swift`、`UIKit/EditorTimelineUIView.swift`、
  `UIKit/EditorViewController.swift`、`PreviewZone.swift`、`TimelineLayout.swift`、`EditorView.swift`、
  `Tests/…/TrackInteractionReducerTests.swift`(新, 16 用例)
- 文档：`RESEARCH-017`（§2 S3 行 + §6 更正版）、`TASK-UIA-041`、
  `docs/reviews/QUESTIONNAIRE-UIA-041-轨道交互收敛与视觉保真.md`(新)
- 池：`docs/tasks/TODO-POOL-门禁真机待办池.md` **[19]**（内核缺 set track muted ABI）
- 坑册：**P128**（模型不支持读图）、**P126 更正+第三/四次复发**（本机 grep 是 toybox 0.8.13，不支持 `\|`）、
  **P129**（os(iOS) 文件在 macOS SPM 中不编译 + 两端 Pods 各跑一次 pod install）

---

## 补记七：UIA-042 预览红框修复 + 编辑器 UIKit 布局迁移 SnapKit —— 2026-10-14，WorkBuddy（集成机）

### 1. 根因（用户原始 `Unable to simultaneously satisfy constraints` 日志）

编辑页预览区选中红框 `previewSelectionBorder`（U1 S11）两条独立病因：
- **① `NSAutoresizingMaskLayoutConstraint` 冲突**：该子视图漏设
  `translatesAutoresizingMaskIntoConstraints=false`，系统自动生成 `minX==0/width==0/height==0`
  的 mask 约束，与手写 `centerX/centerY + width==0.5625*height` 互不满足。
- **② 布局欠定**：原代码只有 center+比例约束、**没有定尺约束**，系统把尺寸解成 0×0，
  红框「存在但不可见」——U1 S11 等于假功能。

两条 = 「约束冲突 + 功能不可见」孪生故障（坑册 **P130**）。

### 2. 决策与落地（ADR-0041，已批准）

编辑器 UIKit 布局**统一迁移 SnapKit**，从机制根除「忘关 mask」整类 bug：
- `ChuanqiCutEditor.podspec`：`s.ios.dependency 'SnapKit', '~> 5.7.0'`（iOS 专属，钉 5.7.1，MIT）。
- `EditorViewController.swift`：`import SnapKit`；四区栈 + 预览子视图改 DSL；
  `applyCanvasAspect()` 用 `snp.remakeConstraints`（MTK：`top/bottom+centerX+width=height×aspect`；
  红框：`center+height=容器+width=height×aspect`，修正 0×0）。
- `EditorTransportBarView` / `EditorToolbarUIView` / `EditorTimelineUIView`：原生
  `NSLayoutConstraint.activate` + 手动关 mask 全替换为 SnapKit DSL。
- iOS 端 `bundle exec pod install` 落地 SnapKit 5.7.1；mac 端 mac 专属依赖不拉入、`pod install` 通过。

### 3. 数字（本机 macOS 26.7.1 / Xcode 26.6 / Swift 6.3.3 / Intel x86_64；2026-10-14 实测，**真实命令输出**）

| 验证项 | 命令 | 结果 |
|---|---|---|
| iOS 壳构建 | `cd apps/apple/ios && xcodebuild -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutApp -destination generic/platform=iOS build` | **BUILD SUCCEEDED** |
| macOS 壳构建 | `cd apps/apple/mac && xcodebuild -workspace ChuanqiCut.xcworkspace -scheme ChuanqiCutMacApp -arch x86_64 ONLY_ACTIVE_ARCH=YES build` | **BUILD SUCCEEDED** |
| 残留原生布局 | `grep -rnE 'NSLayoutConstraint|translatesAutoresizingMaskIntoConstraints' …/UIKit/` | **0 处代码**（仅注释命中） |
| mac pod install | `cd apps/apple/mac && bundle exec pod install` | 成功（exit 0） |
| `swift test`（Editor 包） | — | **未跑**：macOS SPM 跳过 `#if os(iOS)`（P129），不以之替代壳构建 |
| 全量门禁 | `run_gate.sh` | **未跑**（按约定需先询问） |

### 4. 状态与剩余

- UIA-042 代码与双壳构建**已通过**；卡面状态：**📋 未标记完成**，原因 = **真机问卷未回收**（ADR-0034）。
- 问卷：`docs/reviews/QUESTIONNAIRE-UIA-042-预览选中红框与布局保真.md`（已生成，待传哲实测）。
- 未做/待办（已挂号不丢）：SwiftUI 侧 `EditorTimelineView` 同类布局未动（本批 Scope 仅 UIKit）；
  红框视觉尺寸/线宽 [E]，以真机走查校准为准。

### 5. 本批工程教训 → **P130**（已入坑册）

- **P130·a**：`NSAutoresizingMaskLayoutConstraint` 冲突 = 子视图漏关 autoresizing mask，
  统一 SnapKit（自动置 false）根除。
- **P130·b**：布局欠定（只 center+比例、无定尺）→ 0×0 不可见；覆盖层必须至少有一组定尺约束
  （edges / 具体 width·height），比例只能作派生。

### 6. 本批交付物

- 代码（写集 `apps/apple/packages/ChuanqiCutEditor/**` + `ChuanqiCutEditor.podspec`）：
  `EditorViewController.swift`、`EditorTransportBarView.swift`、`EditorToolbarUIView.swift`、
  `EditorTimelineUIView.swift`、`ChuanqiCutEditor.podspec`
- 文档：`ADR-0041`、`TASK-UIA-042`、`docs/reviews/QUESTIONNAIRE-UIA-042-预览选中红框与布局保真.md`、
  `docs/handoff/HANDOFF-023-UIA042-SnapKit迁移与红框修复会话交接.md`、
  `docs/COCOAPODS.md` §7（功能 Pod 第三方依赖）、`.ai/modules/ui-apple.md`（UIA-042 段）
- 坑册：**P130**（忘关 mask 冲突 / 布局欠定 0×0）

---

## 补记八 · 进编辑页必现 SIGSEGV 的定位与修复（2026-10-14 22:15，WorkBuddy 集成机）

### 1. 现象与决策链

| 时间 | 谁 | 事项 |
|---|---|---|
| 16:21 | 传哲 | 报「进入编辑直接卡住」并附 Xcode 暂停栈（trait 传播 → `[UIView superview]` → `CALayerGetSuperlayer`）。**未改代码**，先给读栈结论 + 三条真机诊断路径。 |
| 21:28 | 传哲 | 「已连上手机，你直接跑起来看」+ 让参考 ZCode 的联调套路。→ 采用 `devicectl --console` + 环境变量探针（`HANDOFF-020` §4 既有配方）。 |
| 21:34 | 本机（集成机） | 真机一进编辑页 **signal 11 必现**（不是"卡住"）。取栈两条外部通道均失效（P132），遂加进程内取证通道 `DebugCrashDumper`。 |
| 21:45 | 本机 | 拿到完整栈并用设备符号符号化：根因指向「trait 下钻时 superview 读到坏指针」。 |
| 21:48 | 本机 | 退回 HEAD（UIA-042 前）**同样崩** → 排除今天的 SnapKit 迁移，确认为存量缺陷（决策：不再怀疑 UIA-042，继续向组件内二分）。 |
| 22:00–22:05 | 本机 | 6 组组件对照，锁定 `TimelineContentView` 的 backing layer 全清。 |
| 22:09 | 本机 | 修复（专用自绘容器层 `canvasLayer`）+ 复验通过；临时诊断开关全部撤除。 |

### 2. 根因

`EditorTimelineUIView.swift` 的 `TimelineContentView.rebuild`：

```swift
layer.sublayers?.forEach { $0.removeFromSuperlayer() }   // ← 元凶
```

`layer` 是 UIView 的 backing layer，子视图（主轨右端「+」按钮）的 layer **也在它的
sublayers 里**，被一并拔掉。UIKit `subviews` 仍持有该 view，layer 却已离树 →
CA 首次提交事务走到「有 view / 无 layer」的畸形状态 →
`_parentTraitEnvironment → superview → CALayerGetSuperlayer` 解引用野指针 → SIGSEGV。

二分证据（真机实测）：摘时间线视图不崩 / 摘 addButton 不崩 / 不 rebuild 不崩 /
裸 UIView 顶替按钮照崩（证明与按钮类型无关，条件是「有子视图」+「清层」同时成立）。

### 3. 修复（治本，不留临时方案）

`TimelineContentView` 新增专用自绘容器层 `canvasLayer`：init 挂 `layer.addSublayer(canvasLayer)`、
`layoutSubviews` 内 `canvasLayer.frame = bounds`；rebuild 内 9 处自绘层改挂 `canvasLayer`，
清空只清 `canvasLayer.sublayers`。**子视图层永不被触碰**。

### 4. 写集

- `apps/apple/packages/ChuanqiCutEditor/Sources/ChuanqiCutEditor/UIKit/EditorTimelineUIView.swift`（修复）
- `apps/apple/ios/iOSApp/DebugCrashDumper.swift`（**新增** DEBUG 取证通道）
- `apps/apple/ios/iOSApp/HomeView.swift`（**新增** `CQ_AUTO_PUSH_EDITOR=1` 自动 push 探针）
- `apps/apple/ios/iOSApp/ChuanqiCutApp.swift`（挂 DebugCrashDumper）
- 与内核批次（B0/B5.5）写集不相交。

### 5. 验证（机器环境：iPhone 17 Pro / iOS 26.6.1 (23G83) DEBUG 包；本机 macOS 26.7.1 / Xcode 26.6）

| 验证项 | 结果 |
|---|---|
| push 路径 `CQ_AUTO_PUSH_EDITOR=1`，25s | **零 crash、零约束冲突** |
| 编辑页直挂 `CQ_AUTO_ROUTE=editor`，25s | **零 crash、零约束冲突** |
| 首页默认路径 15s | 零 crash |
| iOS 壳 `-scheme ChuanqiCutApp -destination generic/platform=iphoneos` | **BUILD SUCCEEDED** |
| macOS 壳 `-scheme ChuanqiCutMacApp -arch x86_64 ONLY_ACTIVE_ARCH=YES` | **BUILD SUCCEEDED** |
| 全量 `run_gate.sh` | **未跑**（按约定需先询问传哲） |

### 6. 拍板与待办

- 修复方案（专用容器层而非「清层时跳过子视图」的补丁）由本机按 ADR-0034「严禁临时方案」选定，
  **待传哲确认**。
- **待传哲目检**：canvasLayer 改动后时间线图层位置/层级是否视觉一致（已追加进
  `QUESTIONNAIRE-UIA-042`）。目检回收前本修复不标记完成（ADR-0034）。
- 坑册：**P131**（backing layer 全清 → SIGSEGV）、**P132**（真机崩溃取证通道与 atos 配方）。

---

## 补记九 · 治理落地：图层卫生门禁化（2026-10-15，WorkBuddy 集成机）

- **起因**：传哲要求对 2026-10-14 的 SIGSEGV 出复盘，并回答「静态检查 / CR 能否避免」。
- **新增**：`tools/compliance/check_uiview_layer_hygiene.py`（R1 失败 / R2 告警，
  排除 Pods，匹配前剔注释，保留 `cq-allow:` 逃逸阀）；接入 `tools/ci/run_gate.sh` **步骤 2c**。
- **实测数字（本机 macOS 26.7.1 / Xcode 26.6）**：
  | 输入 | 结果 |
  |---|---|
  | 当前 `apps/apple`（116 文件） | PASS，R1 违规 0 |
  | 修复前版本（`git show HEAD:…EditorTimelineUIView.swift`） | FAIL，命中第 321 行 + R2 混排 ×8 |
  | 反例探测（注释反例 / 容器层 / 逃逸阀） | 零误报 |
- **结论**：静态检查能拦「同一写法复发」，拦不住等价语义的其它形态 →
  兜底靠 L1 容器层约定 + L3 真机取证（DebugCrashDumper / CQ_AUTO_PUSH_EDITOR）。
  **CR 基本拦不住**：危险来自「UIView 有没有子视图」这个隐式前提，
  且它由后来一次合法提交（加「+」按钮）激活 —— CR 只看 diff，看不到跨版本组合效应。
- **未跑**：全量 `run_gate.sh`（按约定需先询问传哲）。

---

## 补记十 · UIA-043 编辑页视觉改版（对标 App单色系）（2026-10-15，WorkBuddy 集成机）

- **起因**：传哲真机截图 `IMG_2645.PNG` 反馈编辑页「丑到爆」，要求按对标 App（行业标杆）
  的 UI/操作范式整改 —— 「不是抄袭，UI 和操作照抄，代码自己实现」。
- **前置冲突与裁定**：UIA-042（SnapKit 迁移+红框）代码完成但**未提交**、**问卷未回收**，
  与本批写集完全重叠 → 提交 A/B/C 三案请传哲裁。
  **传哲 2026-10-15 13:18 拍板 C**：与 UIA-042 **同批同 commit** 交付，
  `QUESTIONNAIRE-UIA-042-*.md` **作废**（保留文件、标作废），改发合并问卷。
- **传哲拍板三事项**：① 撤销/重做 → 与播放、时间码同栏；② 顶栏「导出」本期显示（置灰）；
  ③ 编辑页转对标 App单色系，蓝色 accent 退场，主操作白底黑字。
- **实现（写集仅 `apps/apple/packages/ChuanqiCutEditor/**`）**：
  新增 `EditorChromePalette.swift`（分域单色色表 + 尺寸阶梯：底栏 84/图标 22/传输条 44/时间线 140）；
  `EditorTransportBarView` 撤销重做迁入 + 播放水平居中（去灰圆底）+ 时间码右；
  `EditorToolbarUIView` 撤销重做与 spacer 移除 → 6 位等宽、84pt、单色；
  `EditorViewController` 空态去悬浮卡片改白底黑字胶囊、撤销重做出口改挂传输条；
  `EditorTimelineUIView` 新增 `setEmpty(_:)`（空态不画刻度尺/播放头，高度保留）；
  `EditorScreen` iOS 顶栏「导出」置灰（`.navigationBarTrailing` —— iOS 16 最低版本，不能用 17+ 的 `.topBarTrailing`）。
- **机器验证（本机 macOS 26.7.1 / Xcode 26.6 / Swift 6.3.3 / Intel x86_64）**：
  iOS 壳 **BUILD SUCCEEDED**；macOS 壳 **BUILD SUCCEEDED**；
  `check_uiview_layer_hygiene.py` **PASS（117 文件 / R1 0）**；两端 `pod install` 已跑（新增文件，P34）。
- **未跑**：全量 `run_gate.sh`（按约定需先询问传哲）；`swift test` 不作证据（P129）。
- **已知偏差**：iOS 横屏（regular 分支）/ macOS 编辑页仍是旧样式 + 蓝色 accent
  （本批只覆盖 compact UIKit 路径，横屏与 macOS 惯例化另行立项）；尺寸为估算 [E]。
- **工具坑入册**：P133 —— BSD grep 不支持 `\|`，或条件自查必须走 Grep 工具（本次出现假阴性）。
