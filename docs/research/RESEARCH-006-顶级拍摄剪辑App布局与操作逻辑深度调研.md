# RESEARCH-006：顶级拍摄剪辑 App 布局分区与操作逻辑深度调研

> 日期：2026-10-05
> 调研时点：2026-10-05，来源为公开网络资料（文末列来源），未做真机走查
> **数字纪律**：本文所有第三方数字均为公开资料转述或估算 **[E]**，未实测，不得作为验收阈值；无法核实的具体控件排布标 `[hypothesis]`。
> 上游需求：用户命题「调研一下优秀的拍摄编辑的UI布局与面板逻辑，要全球顶级的设计与操作逻辑」
> 上游调研：**RESEARCH-004**（页面级视觉范式 / 设计系统 / 布局骨架）、**RESEARCH-005**（面板容器四原型 P1~P4 / 四端布局）——本文**继承其结论不重复论证**，增量在**操作逻辑与面板切换规则**（前作只到范式层，未拆到控件排布、手势、槽位切换）
> 下游：UIA-015（iOS 相机页）/ UIA-016（iOS 剪辑页）/ UIA-017（macOS 惯例化）/ UIA-019（面板框架）Spec 撰写时的操作逻辑输入（§5 delta 表）；**不新增 ADR**（纯调研，无架构变更）

---

## 1. 调研要回答的问题与「顶级」的界定

RESEARCH-004/005 回答了「长什么形状」（页面范式、容器原型），本文回答「**怎么操作、面板怎么换**」：

1. 拍摄页：控件分区（top/left/right/bottom）、手势清单、手动参数的暴露时机；
2. 编辑页：工具栏层级切换规则（一级 ↔ 片段级 ↔ 参数面板）、上下文驱动、手势词汇表；
3. 跨产品有什么**公认规律**可直接采纳、有什么**明确不该抄**；
4. 对本仓任务批次的 delta（RESEARCH-004/005 没覆盖的部分）。

**「顶级」的界定**（三者居其一）：① Apple Design Award / App Store Editors' Choice / 红点 iF 等设计奖；② 全球规模头部（CapCut、Edits、TikTok）；③ 专业圈公认标杆（FCP、Resolve、Blackmagic Camera）。覆盖清单：

| 赛道 | 对象 | 顶级依据 |
|---|---|---|
| 专业相机 | Blackmagic Camera / Kino / Halide / Final Cut Camera / FiLMiC Pro | ADA 2024（BMD）、Editors' Choice（Kino）、Apple 官方（FC Camera）、老牌专业（FiLMiC） |
| 社交拍摄 | iOS 26 系统相机 / TikTok / Instagram Reels / Snapchat | 系统标准 + 全球规模 |
| 移动剪辑 | CapCut / Edits / VN / Videoleap / Splice | 规模第一 + 平台对标 + 多端验证 |
| 专业剪辑 | FCP Mac / Resolve / FCP iPad / Premiere / CapCut 桌面 | 专业标杆 + iPad 触控标杆 + 桌面对照 |

---

## 2. 拍摄页逐家深拆

### 2.1 Blackmagic Camera for iOS —— 「常驻芯片条」广播级范式

- **分区**：取景全屏；顶部一排**常驻参数芯片**（帧率/快门角/白平衡/ISO/tint，单击直改）+ 镜头选择、时码、LUT、编解码等芯片（App Store 官方文案「与获奖电影机同界面」）；底部快门 + 镜头胶囊 [E]；HUD 承载全部核心控件。
- **参数暴露**：**常驻**——所有专业参数同时可见。信息密度高、零钻取，但学习成本也高。
- **佐证与荣誉**：ADA 2024 Innovation 类获奖；红点/iF/Good Design（red-dot.org）；免费提供 ProRes / Apple Log / 时码同步 / 多机位控制 / 直播（3.2，2025-11）。
- **对我们的意义**：这是「专业机 FAITHFUL 复刻」极，与我们轻剪辑用户不匹配，但其「芯片单击直改、不进二级菜单」的**改值方式**值得吸收。

### 2.2 Kino（Lux）—— 「直觉优先」按需浮层范式

- **理念**：官方称 "instinctive"——**默认全自动开箱即用，手动参数按需唤出**（MacStories 首评）。
- **分区**：控件双行布局（细节未逐项核实 [E]）；手动对焦 = 点 AF 键后出现**平滑跟焦拨盘**（ProVideo Coalition）；曝光用快门角/快门速度，ISO/WB 手动；曝光与 WB **独立锁定**（RedShark）。
- **招牌**：**Instant Grades**——拍摄时实时套用电影感色彩预设（即 LUT 预览卡），评论公认核心卖点；App Store Editors' Choice（ADA 2025 获奖信息未核实 [hypothesis]）。
- **对我们的意义**：轻剪辑用户该抄的范式：**自动是默认态、手动是浮层、色彩预设是一级入口**。

### 2.3 Halide（Lux，照片）—— 单手热区 + 手势优先

- 官方明确「所有机型单手操作」，控件沿**拇指热区**布置；自动↔手动无缝滑动切换；快门上/下滑调曝光等手势优先于菜单 [E]。
- **对我们的意义**：手势词汇表（滑动即调参、不进菜单）+「布局服务于握持姿态」的设计出发点。

### 2.4 Final Cut Camera（Apple 官方）—— 极简 + 生态

- 取景屏**极简**：全部手动参数（WB/曝光/对焦/快门/ISO）收进**一个 Camera Settings 按钮**按需弹出（Apple Support）；差异价值在生态——Live Multicam 连接至多 4 台设备、音频+时码自动对齐。
- **对我们的意义**：Apple 自己做「给剪辑用的相机」时选择的也是**按需浮层**范式，佐证 Kino 路线；多机位/时码超出本期范围。

### 2.5 FiLMiC Pro v7 —— 浮层前置 + 自定义，订阅反噬

- v7 重构：核心操作环 + **用户可自定义功能键** + info slider + **Quick Action Modals**（关键功能浮层前置减少钻菜单）（NoFilmSchool/CineD）。
- 槽点：Bending Spoons 收购转订阅后口碑长期反弹，「免费的 Blackmagic」成为出口——商业模式反噬 UI 口碑的实例（与 UI 无直接关系，记录为行业教训）。

### 2.6 Apple 系统相机（iOS 26 改版）—— 「高频下沉」与肌肉记忆教训

- **分区**：顶左 = 格式状态（分辨率/帧率，可点改）；顶右 = 情境快捷开关（闪光灯等按条件出现）+ 六点全功能菜单；**模式切换移到快门下方**（默认只露照片/视频，拖动展开更多）；相册缩略图与翻转镜头下移到快门两侧**拇指区**（Macworld）。整体 = **高频下沉拇指弧、低频悬浮顶栏**。
- **教训**（对改版类工作最有价值）：① 模式切换滑动方向与 iOS 18 相反、破坏肌肉记忆，引发大范围批评（ZDNET/NN/g《Liquid Glass Is Cracked》），Apple 在后续版本加回「经典模式切换」设置项；② 玻璃材质在亮背景可读性弱，系统加了不透明度开关。
- **对我们的意义**：控件分区照它抄没有教育成本；**改版必须保留旧交互回退**这条要写进走查清单。

### 2.7 TikTok —— 「拍摄→编辑→发布」一根流水线

- **分区**：顶中 =「添加音乐」（**先选曲后拍摄**，卡点创作前置）；**右竖列**（录制前设置）翻转→速度→滤镜→美化→计时（顺序随版本变 [E]）；底部 = 左特效、中快门（按住录/松手停）、右相册上传；时长选择在快门正上方（15s/60s/3m/10m，上限 60m [E]）。
- **反馈**：顶部进度条按所选时长填充、支持分段累计；倒计时数字。
- **流水线**：拍完 ✓ → **快速编辑页**（音乐/文字/贴纸/滤镜/变声）→ 发布页。拍摄与剪辑是一根管子，不是两个功能。

### 2.8 Instagram Reels 与 Snapchat —— 左列工具 / 单指变焦

- **Reels**：左竖列（Effects→Timer→Layout→Speed，顺序 A/B 变动 [E]）+ 时长选择 + 模板入口；Align 对齐叠影辅助转场。
- **Snapchat**：招牌交互 = **按住快门录制的同一根手指上下滑即变焦**，变焦滑条吸附快门弹出——单指完成录+变焦（iMore/UX 文献一致 [E]）；界面极简，功能藏手势里、发现性差（公认槽点）。
- **对我们的意义**：单指变焦是移动拍摄公认最优解；但「藏手势」要有度，主功能必须可见。

---

## 3. 编辑页逐家深拆

### 3.1 CapCut / 剪映手机版 —— 「一个槽位、两套内容」的行业共识

- **三段式**：预览（约 45% [E]）/ 时间线 / 底部工具栏，比例不可调。
- **一级工具栏**（项目级）：前几项固定 + 横向滚动，主序列 Edit→Audio→Text→Overlay→Effects→Elements→Filters→Adjust→Format→Canvas（顺序随版本/地区变 [E]）。
- **核心机制**：**选中片段后，一级工具栏被片段级工具条在原槽位整体替换**（Split/Speed/Animation/Volume/Filters/Adjust/Reverse/Freeze/Replace/Delete，按素材类型增减），取消选中即还原——**同一槽位、两套内容、由选中态驱动**。这是全行业移动剪辑面板逻辑的定式（VN/Videoleap 同构）。
- **二级面板**：复杂功能（文字/特效/滤镜/调节）开大幅 sheet（60–100% 屏 [E]），轻参数（音量/速度）用底部滑杆小面板；**无官方划分，全屏与否和功能复杂度正相关 [hypothesis]**。
- **关键帧**：入口在片段工具条的菱形按钮 → 打点后移播放头改属性再加点；曲线在属性面板内下钻——**三层收纳**（片段工具条→属性→关键帧轨道），不占一级。
- **撤销/重做**：固定在预览区顶部，恒可见、不随选中态变。
- **手势词汇表**（Sheetly 汇总）：点选；拖移；**双指捏合时间线缩放 / 双指拖平移**；长按「拿起」片段；片段上左右滑微调；双击开编辑菜单；拖两端 trim；捏合预览缩放画面；拖播放头 scrub。

### 3.2 Edits（Meta，2025-04 发布）—— 编辑器之外的数据闭环

- 发布窗口期对标 CapCut：免费无水印、4K 导出、Instagram 原生一键发 Reels；自动字幕（官方称 100+ 语言 [E]）、提词器、AI 绿幕、beat markers、免版税音乐、草稿分享。
- **差异点**：**发布后 insights**（Reels 表现数据回流编辑器）——「编辑器 + 数据闭环」是轻剪辑工具的差异化方向，纯工具无护城河 [hypothesis]。首年更新 130+ 功能 [E]。

### 3.3 VN —— 轨道语义的显式开关

- 多轨（主视频/B-roll/标题/贴纸/音乐/主音频）+ 单条滚动工具栏 + 选中驱动切换（与 CapCut 同构 [E]）。
- **Main Track Mode**：**Quick Mode**（改动后后续片段自动顺延 / ripple）↔ **Pro Mode**（片段时间固定）。CapCut 隐式处理「吸附 vs 精确控时」矛盾，VN 把它做成显式开关——两种心智各有拥趸 [E]。
- 19 个关键帧预设动画、比例预设（Reels/TikTok/YouTube）。

### 3.4 Videoleap / Splice（Lightricks）—— 情境工具栏双线

- 同一交互基因（选中→情境工具）做两条产品线：Videoleap 进阶（多轨/关键帧/AI 工具在片段级入口），Splice 极简（单主轨、工具直接可达）。参数面板以**分组滑杆**为主、少标签页 [E]。

### 3.5 Final Cut Pro（Mac）—— 磁性时间线 + 播放头中心

- **单窗口四区**（Browser/Inspector/Viewer+磁性时间线），无浮动面板。
- **磁性时间线哲学**：B-roll/字幕/音乐作为**连接片段锚定在主片段关系上**（不是绝对时间码），移动主片段整体带走的；消空隙是默认。**Position 模式**退回传统轨道行为——「新范式为默认、旧范式为逃生门」的范本。
- **播放头中心式编辑**：一切以播放头/skimmer 为坐标原点，三角色一键：**E=Append / W=Insert / D=Overwrite / Q=Connect**。用户先想「去哪」再选「怎么放」（角色），而非先选工具再选位置——专业端效率天花板。
- **Inspector**：按 **Video/Audio/Color** 属性域分区，选中片段才显示其参数（**选区即上下文**）。

### 3.6 DaVinci Resolve —— Pages 按工作流阶段分页

- 顶部 Page 一级切换（Media/Cut/Edit/Fusion/Color/Fairlight/Deliver）= **按任务阶段重组全部面板**，而非隐藏/显示面板。
- **Cut 页**：为速度设计的「单屏完成一切」——垂直双时间线（上全局/下细节）、Source Tape、Fast Review、ripple overwrite/close-up 等一键完成；官方逻辑：Cut 页作为第二编辑页可以激进创新而不破坏传统 Edit 页，同一项目互通。
- **Color 页**：节点图 = 顺序显式化的非破坏管线；Pre-Clip/Clip/Post-Clip 三层分组。
- **对我们的意义**：分页适合 Resolve 级功能密度；我们用不到，但「Cut 页精神」（高频操作一键化、单屏）值得渗入设计。

### 3.7 Final Cut Pro for iPad（2.x）—— 触控混合式标杆

- Viewer + 可显隐 Browser/Inspector + 磁性时间线 + **底部常驻工具行**（含 browser/inspector 显隐开关——两个按钮全关即隐藏浏览器，Apple 官方《Customize the Edit screen》）。
- 手势：捏合缩放时间线（含放大转场细节）、按住拖移、触屏 jog wheel；Pencil **Live Drawing** 画面上手写即生成标题；悬停预览（M2）；2.2 起多选批量改参数、竖屏支持。
- 批评：帧级精确修剪与多轨管理弱于 Mac 版，专业操作依赖外接键盘 [E]。

### 3.8 Adobe Premiere —— 自由浮动的代价

- 任何面板可拖出浮动/任意停靠 + **workspace 预设**（布局快照，按任务切换）。自由度最强，代价：社区大量「面板停不回去」求助帖（可发现性差）、布局漂移导致教学/协作不一致 [E]。
- **对我们的意义**：反面参照——**布局自由度是用一致性换的**，轻剪辑产品不该付这个代价。

### 3.9 CapCut 桌面版 —— 扁平固定四区

- 四区固定不可浮动：左素材库（媒体/音频/文字/贴纸/特效/转场**标签页**）、中预览、右**情境检查器**、下时间线；无浮动、无 workspace。
- **严格按剪辑工序排布**：左选素材→拖时间线→右上改参数→中间看预览，零布局学习成本；AI 功能做成素材库里的「一键预设」而非参数面板。
- **对我们的意义**：与 FCP 一起构成「固定布局 + 情境 Inspector」的双证；macOS 分支照此即可。

---

## 4. 跨产品规律提炼（本文核心产出）

### 4.1 拍摄页操作逻辑八律

| # | 规律 | 例证 |
|---|---|---|
| 1 | **高频下沉拇指弧**：快门/模式/相册/翻转全在底部；顶栏只留低频与状态 | iOS 26 相机、TikTok、Reels 全体 |
| 2 | **侧列只放「录制前设置」**：滤镜/美化/速度/计时，录制中无需触碰 | TikTok 右列、Reels 左列 |
| 3 | **自动默认、手动按需浮层**（轻用户向）；或常驻芯片条（专业向）。两极之间无中间态 | Kino/Halide/FC Camera vs Blackmagic/FiLMiC |
| 4 | **色彩预设是一级入口**，拍摄中实时可换 | Kino Instant Grades、TikTok/Reels 滤镜 |
| 5 | **单指变焦**（按住快门上滑或缩放拨盘），双指捏合是补充 | Snapchat、iOS 相机缩放拨盘 |
| 6 | **状态集中一条反馈带**：录制进度/剩余时长/计时，顶置或环绕快门 | TikTok 进度条、Snapchat 红环 |
| 7 | **拍完必进下一步**：结果页主按钮 = 去编辑/发布，拍摄与剪辑是一根流水线 | TikTok ✓、iOS 26 前的相册缩略图、我们 RESEARCH-004 结果页方案 |
| 8 | **改版保肌肉记忆回退**：滑动方向、控件位置的破坏性变更必须留经典模式 | iOS 26 相机争议与回调（ZDNET/MacRumors） |

### 4.2 编辑页面板逻辑八律

| # | 规律 | 例证 |
|---|---|---|
| 1 | **一个工具栏槽位、两套内容、选中驱动**：项目级 ↔ 片段级替换，取消选中还原；无第三种悬浮条 | CapCut/VN/Videoleap 全体一致 |
| 2 | **撤销/重做恒置顶**（预览区附近），不随选中态变 | CapCut/Edits/VN/Videoleap 一致 |
| 3 | **参数永不遮挡预览主线**：手机在下半屏、桌面在右栏（RESEARCH-005 §4.10 B 同结论，本文补证据链） | 全体 |
| 4 | **二级面板 = sheet，复杂度决定幅度**：重功能近全屏、轻参数底部小面板 | CapCut（划分未官方化 [hypothesis]） |
| 5 | **关键帧三层收纳**：片段工具条 → 属性 → 关键帧轨道，不占一级 | CapCut |
| 6 | **面板组织三范式**：按任务分页（Resolve）/ 按选区情境化（FCP、CapCut Inspector）/ 按用户自由度浮动（Premiere）。轻剪辑 = 固定区 + 情境 Inspector，不学浮动 | 三者对照 |
| 7 | **Inspector 按属性域分区分组**（Video/Audio/Color 或变换/调色/滤镜），选区决定显示什么 | FCP、CapCut 桌面、Pixelmator（005 §4.8） |
| 8 | **新范式默认 + 旧范式逃生门**：磁性吸附默认、Position 逃生（FCP）；Quick/Pro 显式开关（VN） | FCP、VN |

### 4.3 手势词汇表（移动剪辑事实标准，直接采纳）

双指捏合时间线缩放、双指拖平移、长按「拿起」片段、拖两端 trim、点选、拖播放头 scrub、捏合预览缩放画面。各家高度趋同，**自己发明手势 = 教育成本** [E]。

### 4.4 共性设计哲学

1. **预览即真相（WYSIWYG）**：调参实时反映、拍摄即所见（LUT/美颜进录制流）；
2. **非破坏**：行业从 LUT/Adjust 到节点图全线非破坏，Undo 全覆盖；
3. **一致性 > 自由度**（轻剪辑定位下）：单窗口固定区，放弃浮动面板与 workspace；
4. **流水线思维**：拍摄→编辑→发布（→数据回流，Edits）不是四个页面，是一根管子。

---

## 5. 对本仓的落地映射（delta 表）

> RESEARCH-004 §6/§7 与 RESEARCH-005 §5/§6 的结论全部维持；下表只列**本文新增**的输入，Spec 撰写时合入对应任务。

| 任务 | 本文新增输入 | 与前作关系 |
|---|---|---|
| **UIA-015 相机页** | ① 快门区拇指弧布局：相册缩略图/翻转放快门两侧（iOS 26 分区）；② 单指变焦：按住快门同指上滑 or 缩放拨盘（规律 5）；③ 手动参数走 **Kino 式按需浮层**（默认自动，点按唤出拨盘），**不学** BMD 常驻条；④ 滤镜条 = Instant Grades 式一级实时预设卡（004 已定缩略图卡，补「拍摄中实时可换」语义，已有 LUT 链路）；⑤ 录制反馈带（进度/剩余，规律 6）；⑥ 模式滑条保留与系统一致的滚动方向，走查清单加「肌肉记忆回退」项（教训 8） | 004 §6.1 骨架不变，补操作层 |
| **UIA-016 iOS 剪辑页** | ① **工具栏槽位状态机**：一级项目工具栏 ↔ 片段编辑条**同槽替换**（规律 1，CapCut 定式）——这是对 004 §3.4「底部图标工具栏 + 二级抽屉」的关键细化；② 撤销/重做恒置预览区顶（规律 2）；③ 手势词汇表按 §4.3 对齐（ADR-0012 拖拽提交语义不变）；④ 关键帧入口预留三层收纳（本期只留位） | 004 §6.2 / 005 §5.1 不变，补交互层 |
| **UIA-017 macOS** | ① 固定四区 + **情境 Inspector**（选中才显参数）= FCP/CapCut 桌面双证（005 §5.3 已有，升级为硬要求）；② Inspector 分组按属性域（变换/速度 → Video 类；滤镜/调色 → Color 类）；③ **明确不学** Premiere 浮动面板与 workspace；④ 播放头中心精神轻量版：追加式导入已同构（importMedia 语义），快捷键空格/JKL（004 已列）不扩到 E/W/D/Q | 004 §6.3 / 005 §5.3 强化 |
| **UIA-018 时间线** | 双指缩放/平移进入手势清单；片段态视觉沿 004 §6.4；VN Quick/Pro 轨道语义开关记 BACKLOG（非本期） | 增量小 |
| **UIA-019 面板框架** | PanelRoute 状态机增加**工具栏槽位状态**（项目级/片段级，随选中态自动切换）；PanelSection 分组采纳属性域惯例；手势词汇表进组件库行为规范 | 005 §6 六条结论的第 1/3 条扩展 |

**明确不采纳清单**（防范围膨胀）：Resolve Pages 分页（功能密度不到）、Premiere 浮动面板/workspace（一致性代价）、Blackmagic 常驻芯片条（用户群不符）、FiLMiC 自定义功能键（过度定制）、订阅制商业设计（非 UI 范畴）。

---

## 6. 风险与开放问题

1. **未核实项汇总** [hypothesis/E]：Kino ADA 2025 获奖与否；Blackmagic 右竖条/底栏逐项内容；Kino 双行布局细节；Edits 工具栏逐项顺序；TikTok 右列顺序与时长档位的版本差异；Reels 左列顺序（A/B 变动）；小红书/剪映拍摄页分区（二手综合）。**不得作为验收阈值**；如需硬结论需真机截图走查。
2. **竞品 UI 精确排布的验证方式**：公开资料粒度有限（官方不给布局图），建议后续开一个小任务用真机走查 2~3 个标杆 App（CapCut/iOS 26 相机/Kino）截图核对控件顺序，作为 UIA-015/016 Spec 附图。
3. **本文 delta 与 UIA-014~019 Spec 的合流**：RESEARCH-004/005 的任务批次尚未全部立 Spec；本文结论在 Spec 撰写时合入，避免三份调研漂移（建议 Spec 引用本文 §5 delta 表，不复制全文）。
4. 手势词汇表趋同为 [E]（三家以上一致），未见官方交互规范文档背书——置信度高但非官方。
5. Edits 的 insights 闭环属产品/增长层，是否进入我们的路线超出本文范围，仅登记为方向 [hypothesis]。

---

## 7. 来源

**专业相机赛道**
- [App Store：Blackmagic Camera](https://apps.apple.com/us/app/blackmagic-camera/id1575225775)（官方描述：与获奖电影机同界面、单点改参数）
- [Apple Design Awards 获奖者页](https://developer.apple.com/design/awards/)；red-dot.org（BMD Camera 红点/iF/Good Design 记录）
- [MacStories：Kino 首评](https://www.macstories.net)；[RedShark News：Kino 评测](https://www.redsharknews.com)；[ProVideo Coalition：Kino 跟焦拨盘](https://www.provideocoalition.com)；[Pocket-lint：Kino Instant Grades](https://www.pocket-lint.com)
- [Apple Support：Final Cut Camera 使用与多机位](https://support.apple.com)
- [No Film School：FiLMiC Pro v7 UI 与订阅](https://nofilmschool.com)；iphoneographers.tv（FiLMiC 现状）

**社交拍摄赛道**
- [Macworld：iOS 26 相机全面变动图](https://www.macworld.com/article/2857154/ios-26-has-a-new-camera-app-heres-whats-new-and-how-to-find-everything-thats-moved.html)
- [ZDNET：iOS 26 相机肌肉记忆争议与 Apple 回调](https://www.zdnet.com/article/this-ios-26-update-ruined-the-iphone-camera-app-for-me-then-apple-saved-the-day/)
- [MacRumors：iOS 26 相机指南](https://www.macrumors.com/guide/ios-26-camera-app/)；[NN/g：Liquid Glass Is Cracked](https://www.nngroup.com)
- [TikTok 官方帮助：Camera tools / Editing](https://support.tiktok.com/en/using-tiktok/creating-videos/camera-tools)
- Reels/Snapchat：flowshorts.app、slidycreator.com、iMore（Snapchat 单指变焦）

**移动剪辑赛道**
- [TutsPlus：CapCut 教程](https://photography.tutsplus.com/tutorials/how-to-quickly-use-capcut-for-video-editing-tutorial-2024--cms-108707)；[Sheetly：CapCut 手势清单](https://sheetly.org/cheatsheets/capcut)；[CapCut 官方帮助](https://www.capcut.com/help/interface-and-settings)
- [TechCrunch：Meta 官宣 Edits](https://techcrunch.com/2025/01/19/meta-announces-a-new-video-editing-app-called-edits-amidst-tiktok-and-capcut-ban)
- [VN Help Center](https://www.vlognow.me/help/)（Main Track Mode）；editflicks.wordpress.com（VN 界面走查）
- [Lightricks Help Center：Videoleap 教程](https://lightricks.zendesk.com/hc/en-us/articles/6114552482962-Videoleap-Tutorials)

**专业剪辑赛道**
- [Apple：FCP 键盘快捷键](https://support.apple.com/guide/final-cut-pro/keyboard-shortcuts-ver90ba5929/mac)；[FCP iPad 自定义编辑界面](https://support.apple.com/zh-hans/guide/final-cut-pro-ipad/dev8b472bcb8/ipados)；[FCP/Logic for iPad 新闻稿](https://www.apple.com/newsroom/2023/05/apple-brings-final-cut-pro-and-logic-pro-to-the-ipad/)
- [Blackmagic：Resolve Cut 页](https://www.blackmagicdesign.com/products/davinciresolve/cut)；davinciresolve21.com（Cut vs Edit）；blog.frame.io（节点分组）
- [Adobe：workspaces](https://helpx.adobe.com/premiere/desktop/get-started/tour-the-workspace/what-are-workspaces.html)、[面板停靠/浮动](https://helpx.adobe.com/my_ms/premiere/desktop/get-started/tour-the-workspace/dock-group-undock-panels.html)
- alex4d.com（磁性时间线机制分析）；[ProVideo Coalition FCP iPad 评测](https://www.provideocoalition.com)；[CineD：FCP iPad 2.1](https://www.cined.com/final-cut-pro-for-ipad-2-1-enhance-light-and-color-added/)
