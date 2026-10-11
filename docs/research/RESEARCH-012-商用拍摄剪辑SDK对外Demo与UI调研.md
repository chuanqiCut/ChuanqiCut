# RESEARCH-012 · 商用拍摄剪辑 SDK 对外 Demo 与 UI 调研（该厂商 其创作 SDK × 阿里云 UGSV）

> **日期**：2026-10-10　**归属**：A 线（编辑器/UI）　**状态**：一次性产出，待评审  
> **命题**：该厂商（该厂商云服务）与阿里云对外售卖的拍摄/剪辑整体方案，能不能拿到 demo、UI 有哪些功能、能否参考  
> **与既有调研的关系**：RESEARCH-004/007/008 拆的是**成品 App 的 UI 范式**；本文拆的是**对外售卖 SDK 的交付形态与 UI 装配协议**（面板怎么配置、换皮怎么约定、UI 源码给不给）——不重复，互补。  
> **纪律**：本文数字一律是**厂商文档口径或仓库实测**，不作为我们的验收阈值；推断标 `[推断]`，未拿到的明写「未拿到」。

---

## 0. 一句话结论（先给答案）

| 问题         | 字节 · 该厂商云服务                                                   | 阿里云                                      |
| ---------- | ----------------------------------------------------------- | ---------------------------------------- |
| 有没有对外 demo | **有**。Android 有 APK 直链（实测 HTTP 200，156 MB）；iOS 走 TestFlight | **有**。MediaBox App 内含「短视频制作」入口；源码仓库公开    |
| UI 源码给不给   | **不给**。SDK 概览原文「SDK 暂不会公开提供，如需获取请联系技术支持专员」                  | **给**。iOS/Android 两个仓库 MIT 开源，UI 层源码完整可读 |
| 引擎/二进制     | 商务授权 + License 绑 Bundle ID                                  | 需 License（控制台申请），未授权最多 7 天自测             |
| 参考什么       | **文档**（整套 UI 标注 + 面板 JSON 协议 + 色卡系统）                        | **代码**（UI 分层、Action 动作管道、时间线数据模型）        |
| 我们的可得性     | 能看文档、能装 APK 体验，**拿不到源码**                                    | **能直接 clone 读代码**（唯一真正可抄的源码来源）           |

**结论**：参考**是**可行的，但两家给的东西形态完全不同 —— 该厂商给的是**设计契约**（值得抄架构），阿里云给的是**工程代码**（值得抄实现）。两家都不是「对标 App本体」，而是对标 App能力的**对外裁剪版**，功能面明显比对标 App窄（见 §2.5 实测负结论）。

---

## 1. 字节 · 该厂商云服务「智能视频创作 SDK」（内部名 其创作 SDK / 海外 该厂商海外版创作 SDK）

文档中心：`https://docs.该厂商云服务.com/docs/6839/`（产品 ID 6839）

### 1.1 获取路径与门槛（实测）

| 项                | 结果                                                                                                                                                | 证据                                 |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------- |
| Android Demo APK | `https://cvsdk.volccdn.com/Android/apk/Effects/CV-481.apk` — **实测 HTTP 200**，content-type `application/vnd.android.package-archive`，156,124,795 B | 本次 `curl -I` 实测                    |
| iOS Demo         | TestFlight。文档里出现两个链接：`https://testflight.apple.com/join/FD1iFEQu`（基础拍摄剪辑/剪同款/高光成片三页共用）、`https://testflight.apple.com/join/t46KSKI0`（Demo 体验页）     | 该厂商文档；**有效性未验证**（无法代访问 TF 页，需自己装）   |
| SDK 本体           | **必须商务对接**。SDK 概览原文：「SDK 暂不会公开提供，如需获取请联系我们技术支持专员」                                                                                                 | `该厂商云服务.com/docs/3019/1535822` |
| License          | 与**合同时长 + App Bundle ID** 绑定；接入要求包名与申请时一致                                                                                                         | `docs.byteplus.com` 资源清单页、iOS 快速开始 |
| 商业模式             | 年费 License / 按模块启用付费（Pay-as-you-Activate）/ 付费 UI 定制；**美颜与特效贴纸不在基础包内**（CV 加购）                                                                      | 该厂商海外品牌 产品页                       |
| 版本号              | 文档口径不一致：SDK 版本页写 **iOS/Android V1.7.2（2025-03-19）**，Demo 体验页写 **V4.8.1**。[推断] 两者属不同版本序列                                                           | 两处文档页                              |

**注意**：该厂商中文文档是 **JS 动态渲染**，直接抓取正文会拿到空内容（本次实测 WebFetch 返回空）。有效迂回路径是 **该厂商海外品牌 海外英文文档站 `docs.byteplus.com/docs/video-editor-sdk/*`**（同产品、公开可访问）+ 搜索引擎正文摘要。

### 1.2 UI 功能模块清单（文档口径，非实测）

**拍摄部分**

- 主页：关闭 / 添加音乐（含删除、分割线）/ 拍摄按钮（空态内外圈、进度条、中心色、删除已录制片段、确认、片段节点）/ **拍摄模式栏（2min · 30s · 15s · 拍照）** / 人脸特效
- 右侧侧边栏 6 项，**可排序、可删减、不支持自定义新增**：镜头翻转 / 闪光灯 / 倒计时 / 滤镜 / 美颜 / 倍速（配置 `menuList` + `unfoldCount` 默认 5 + `foldEnabled`）
- 能力：变焦、曝光滑杆、分段拍（可删最近一段）、倍速 0.3/0.5/1/2/3x、画布默认 9:16、选图器、BGM（仅 1 首）、滤镜可调强度、合拍（单独购买）、基础美颜+微整形+美妆（需额外购买 CV）
- 未拿到：网格线、曝光 UI 具体形态

**预览编辑（一级侧边栏 8 项，可排序/删减/折叠）**

- 编辑（进轨道编辑）/ 文字 / 信息贴纸 / 滤镜 / 视频特效 / 特效贴纸(人脸) / 变声 / 展开收起
- 二级：文本（字体/颜色+描边/位置/放大/拖拽/时长/删除）、**录音&变声**（音色如小黄人/扩音器）、人脸特效（2D/3D/复杂）、信息贴纸（**支持相册图片当贴纸**）、动画特效（可叠加）、滤镜（与拍摄共用）、音乐（原声&音乐音量）
- 图片编辑版只有「文字 + 滤镜」两项；图片自动转 3s 视频轨
- **未拿到**：涂鸦、画中画、画面调节（对比度/曝光等）、字幕 —— UI 标注页与功能清单**均未出现**。（产品宣传页提到「关键帧、画中画」是另一条 CK 产品线口径，不等于本 SDK 有对应 UI）

**轨道编辑（重点）**

- 播放控制栏：当前进度/总时长、播放暂停、**撤销/重做（enable/disable 四态 icon）**、全屏预览
- 轨道区至少 3 轨：主视频轨（原声开关、片段间**转场 icon 两态**、选中边框、左右裁剪滑块、时长 tag、变速 tag、静音 tag、添加「+」）、**BGM 轨（独立背景色 + 音频波形）**、**音效轨（独立背景色）**、时间刻度
- 底部工具栏 **8 个一级操作**：**拆分 / 替换 / 删除 / 变速 / 添加 BGM·音效 / 裁剪 / 旋转 / 音量**
- 能力参数：旋转 0/90/180/270、画面任意缩放平移+角度、**画面裁剪 -45°~+45°**、**变速 0.1x~10x**（视频与音频均支持）、**转场时长 0.1s~1.1s**（不影响总时长）、BGM 仅 1 段可截断
- **未拿到**：关键帧 UI、轨道缩放手势/控件、复制片段、片段拖拽换序（文档里的"拖拽"指画布内画面拖拽，非轨道排序）

**草稿箱 / 相册 / 音乐面板**

- 草稿箱：标题栏（返回/标题/**管理**）、卡片（修改日期、选中态、草稿时长）、删除、**空态**（117×117 图 +「暂无草稿」）；支持保存/删除/二编
- 相册选图器：顶部（关闭/标题/Tab 全部·视频·图片）、底部 Docker 栏（删除已选、提示文案、下一步、视频时长）、大图预览页、**权限提示条 + 去设置**；配置类 `AlbumConfig`（`maxSelectCount` 默认 35、`maxDuration`、`enableDocker`、`showGif` 等 11 个开关）
- 音乐面板：列表含音乐名（默认/选中两色）、作者、时长、选中边框、**播放中 gif**、下载状态 icon（未下载/下载中）、**原声开关**、原声音量
- 未拿到：音效面板、音量面板后续条目（页面截断）

### 1.3 交付形态（文档口径）

- iOS 交付：`其创作 SDKKit.xcframework`（真机 arm64 + 模拟器 x86/arm64，含 dSYMs、`PrivacyInfo.xcprivacy`）、`其创作 SDK 组件.bundle`（`BuiltInResource` UI 资源 / `EffectResource` 素材 / `License`）、podspec、`其创作 SDKKit_spm`（SPM 接入）、`其创作 SDK-iOS` **示例代码**
- 资源 bundle 分包：`transitions` / `ModelResource` / `tone`（变声）/ `sound`（音效）/ `sticker` / `ve_effect` / `ComposeMakeup` / `StickerResource` / `fonts` / `music` / `filter` / `duet` / `cutsame` / `Panel_configs` / `RemoteResource`
- 包大小（文档口径）：iOS 全能力 **24 MB**（zip, arm64），剪同款+高光成片 22.8 MB，**UI 显示资源仅 0.4 MB**（素材建议放线上）；Android 拍摄&剪辑 50.67 MB
- **UI 源码**：部分。剪同款明确「支持 UI 换皮」「支持源码接入」；主 UI 以二进制 + 资源 bundle 提供，换皮走**替换同名 icon / 改色卡 / 改文案 key** 三条路，**侧边栏不支持自定义新增元素**
- 多语言接入：文档有 SwiftUI / Flutter / RN / OC / Swift 独立页；但三方评测指出 **RN/Flutter 只发文档未发包** `[推断]`
- 100% 端侧离线、不上传用户内容

### 1.4 最值得抄的一点：面板 = 一份 JSON，UI 完全由配置驱动

这是本次调研**最有价值的结构性发现**：

- 每个面板对应 `Panel_configs/<panel_key>.json`，按 `panelKey`（如 `recorder_sticker`）拉取，**可内置也可服务端下发/按需下载**
- 已挖到的 14 个 panel key：预览编辑 `preview_editor_{music,effect,filter,font,info_sticker,sticker,tone}`、拍摄 `recorder_{beauty,filter,music,sticker}`、轨道 `track_editor_{music,sound,transition}`
- JSON 结构：`data.tabs[] → {uniqueId, titleDict{en,zh}} → subItems[] → {uniqueId, titleDict, builtInIcon, md5, relativePath, param, extra{duration}}`  
  → **分组 / 顺序 / 图标 / 多语言标题 / 资源路径 / 业务参数全在 JSON 里**，客户端 `其创作 SDK 组件` 自动构建 item
- 代码层还有二级开关：`FilterUIConfig` / `其创作 SDK 组件`（`showInEditor` + `showInRecorder` 两个总开关）/ `BeautyUIConfig` / `TransitionUIConfig` 等；侧边栏 `RecorderMenuUIConfig`/`EditorMenuUIConfig`（menuList + unfoldCount + foldEnabled）
- **色卡系统独立成页**：`TextPrimary/Secondary/Tertiary/Quaternary`、`Primary`、`BGPrimary/...`、`Negative` 等，UI 标注页每个元素都标「色卡 Key」，与具体色值彻底解耦

> 这套「面板 JSON + 色卡 Key + 文案 Key」三件套，是他们能做到「2~3 周接入 + 换皮」的地基。

---

### 1.5 该厂商侧真正能拿到的东西：公开 podspec 仓库 + CDN 直链（本次新发现，2026-10-10）

> 首版结论是「该厂商源码拿不到」——**只对了一半**。源码（.m/.swift 实现）确实不给，
> 但**头文件（接口层）与 UI 配置资源可以通过公开渠道整包下载**，而且不需要任何商务流程。

#### 1.5.1 入口：`该厂商云服务/其公开 spec 仓库`（MIT）

- 仓库 `https://github.com/该厂商云服务/其公开 spec 仓库`，描述 "Volcengine CocoaPods specs."，
  **MIT license**，70 stars，3,993 KB，**9071 条目**，**2192 个 podspec**，**63 个组件**
  （实测 HTTP 200；最近 push 2026-10-10，仍在更新）。
- 编辑/创作相关的组件（括号内为 podspec 版本数）：

| 组件 | 版本数 | 是什么 |
|---|---|---|
| `其媒体引擎层` | **315** | 视频编辑器主体（`ios/其媒体引擎层.framework`，MIT） |
| `其编辑语义层` | **111** | **NLE = 非线性编辑内核**（对标 App数据模型层），`ios/Headers/*.h` |
| `其创作 SDKKit` | 10 | 即「智能视频创作 SDK」本体（`其创作 SDKKit.xcframework`） |
| `其轨道 UI 组件库` | 12 | **多轨轨道 UI Kit**（DVE = 编辑器 UI 域） |
| `其依赖注入层` | 6 | |
| `EffectSDK_iOS_TOB` | 6 | 特效 SDK（美颜/贴纸，VE 版） |
| `其编辑器组件` / `其示例工程` | 9 / 15 | ⚠️ **不是视频编辑器**，见下方陷阱 |

**别去 clone 官方 `CocoaPods/Specs` 找这些组件的历史版本 —— 实测不值**（2026-10-11）：

- 官方 trunk（即 `CocoaPods/Specs`）上这些组件**每个只有 1 个版本，且是占位号**：
  `其创作 SDKKit` = `0.0.1`、`其媒体引擎层` = `0.0.1`、`其编辑语义层` / `其轨道 UI 组件库` /
  `其依赖注入层` / `EffectSDK_iOS_TOB` 各 1 个版本。
- 而 `其公开 spec 仓库` 里有 **315 / 111 / 12 / 10 / 6 / 6** 个版本 —— **历史版本全在该厂商自己的仓库**，
  整个仓库只有 **3.99 MB**（对比 `CocoaPods/Specs` 实测 **1.26 GB**、103,383 个 pod）。
- 更快的做法：CocoaPods 官方索引名单 `https://cdn.cocoapods.org/all_pods.txt`
  **只要 1.5 MB / 103,383 行**，几秒下完，直接 grep 就能确认某个 pod 在不在官方源上。
- 补充发现：官方源上另有 `EffectBytedEffectSDK`（4.3.2）、`该厂商海外品牌RTC`、`BytedanceOpenPlatformSDK`
  等该厂商系 pod，但**与视频编辑内核无关**。
- 另外，官方 `github.com/CocoaPods/Specs.git` 作为源在 2022 年起已被 CDN `https://cdn.cocoapods.org/`
  取代；本机 `~/.cocoapods/repos/trunk` 已是 CDN 源（CocoaPods 1.17.0），**`pod install` 不需要全量 spec**。

#### 1.5.2 ⚠️ 陷阱：`其示例工程` 不是视频编辑 demo

`其示例工程/22.9.19` 的 source 指向 Gitee：`https://gitee.com/该厂商云服务/其示例工程.git`
（实测公开仓库，`private: false`，MIT，Objective-C，描述「这是该厂商源demo工程,用于展示demo」）。
名字看着像 Video Editor，但**实际内容是该厂商 SDK 全家桶**：`BDHotfix` / `OneKit` / `RangersAPM` /
`RangersAppLog` / `其编辑器组件` / `其编辑器组件` / `其编辑器组件` / `其编辑器组件` / `Timor` / `其编辑器组件` /
`其编辑器组件` / `其编辑器组件` / `其编辑器组件`。
**495 条目里没有任何 Editor / Record / Track / Draft / Album / Music 模块** —— 对我们看剪辑 UI **无用**，
别在这上面花时间。

#### 1.5.3 CDN 直链规律（实测全部 HTTP 200）

podspec 里的 `s.source` 形如
`https://sf3-ttcdn-tos.pstatp.com/obj/该厂商云服务/<Name>/<Version>/<Name>.zip`
（部分是字面 URL，部分是 `#{s.name}/#{s.version}` 插值，**取号时要自己展开**）。

| 组件@版本 | 直链 | 实测 |
|---|---|---|
| `其轨道 UI 组件库@0.1`（传哲指定） | `.../obj/该厂商云服务/其轨道 UI 组件库/0.1/其轨道 UI 组件库.zip` | **200**，7,375,114 B（7.4 MB） |
| `其轨道 UI 组件库@0.3.3`（最新） | `.../其轨道 UI 组件库/0.3.3/其轨道 UI 组件库.zip` | **200**，6,041,770 B |
| `其编辑语义层@17.5.0.14-NEO170` | `.../其编辑语义层/17.5.0.14-NEO170/其编辑语义层.zip` | **200**，7,202,269 B（7.2 MB） |
| `其媒体引擎层@9.6.2.1-D` | `.../其媒体引擎层/9.6.2.1-D/其媒体引擎层.zip` | **200**，40,388,902 B（40 MB） |
| `其创作 SDKKit@1.1.0` | `.../其创作 SDKKit/1.1.0.1/其创作 SDKKit.xcframework.zip` | **200**，92,363,296 B（92 MB） |

#### 1.5.4 `其轨道 UI 组件库@0.1` 解开后有什么（已下载核验）

```
其轨道 UI 组件库/
├── lib其轨道 UI 组件库.a                      ← 静态库（无源码）
├── Headers/  **147 个头文件**              ← 接口层，全部可读
└── Resources/其轨道 UI 组件库.bundle/
    ├── color.json / layout.json / config.json / font.json
    └── Assets.car
```

**147 个头文件按域分类**（实测）：

| 域 | 数量 | 代表 |
|---|---|---|
| 轨道 / 多轨 | **40** | `其多轨控制器`、`Attacher`、`CollectionView`、`AudioCell/EffectCell/FilterCell` + 对应 ViewModel |
| 蒙版 / 混合 / 边框 | 16 | `其蒙版编辑视图`、`MaskCircleDrawView`、`MaskDrawView`、`其媒体上下文+Blend`、`其轨道组件` |
| 音频 / 波形 | 11 | `其轨道组件`（+ViewModel/Layer）、`其轨道组件`（**节拍点**）、`其轨道组件`（淡入淡出）、`AudioSegmentTag` |
| 时间线 / 片段 | 11 | `其轨道组件`（标尺）+ `TimelineRulerViewModel`、`其轨道组件`（缩放）、`其轨道组件` |
| **关键帧** | **4** | `其关键帧视图` / `ViewModel` / `Item` / `Protocol` ← **文档里没找到的关键帧 UI，这里实证存在** |
| NLE 内核 OC 封装 | 6 | `其时空节点模型+NLE`、`其数据模型+NLE`、`其时空节点模型+NLE`、`其模型层组件+Meepo` |
| 转场 | 3 | `其轨道组件` / `Model` / `其模型层组件+NLE` |
| 媒体上下文 | 8 | `其媒体上下文` + `VideoOperation` / `StickerOperation` / `SlotUtils` / `FilterOperation` 分类 |

**`color.json` 原文（该厂商内部色卡实证）** —— 轨道按**片段类型着色**：

```json
"dve_ui_color_theme"                            : "0xFE6646",
"dve_ui_color_track_filter_cell_background"     : "0x8342E3",
"dve_ui_color_track_adjust_cell_background"     : "0x11862F",
"dve_ui_color_track_effect_cell_background"     : "0xEBAED8",
"dve_ui_color_track_sticker_cell_background"    : "0x5E76EE",
"dve_ui_color_track_text_sticker_cell_background": "0xFBCD60",
"dve_ui_color_track_audio_cell_background"      : "0x343434",
"dve_ui_color_track_audio_cell_default_wave"    : "0xECC66B",
"dve_ui_color_track_audio_cell_sound_wave"      : "0xED8ACE",
"dve_ui_color_track_audio_cell_recorder_wave"   : "0x12882E",
```

**`layout.json` 原文** —— 连按钮尺寸与每帧时间线宽度都是配置项：

```json
"dve_ui_layout_track_origin_sound_button_size"  : "{42,42}",
"dve_ui_layout_track_video_cover_button_size"   : "{42,42}",
"dve_ui_layout_track_time_line_with_per_frame"  : "50",
```

> 这两份 JSON 把 §1.4 从文档推断出的「色卡 Key + 配置化」**变成了可核验的实物**：
> 该厂商的轨道 UI 是**片段类型 → 颜色/尺寸 → JSON 配置**驱动，改配色和尺寸不需要改代码。

#### 1.5.5 `其编辑语义层` 解开后：172 个头文件（已下载核验）

`ios/Headers/` 172 个头文件，**命名直接暴露对标 App的数据模型层**：

- 编辑器：`其模型层组件.h`、`其模型层组件.h`、**`其模型层组件.h`**（提交上下文协议 —— 对应我们的 Command 提交语义）
- 模型：`其数据模型`（+Extension/+Private/+iOS）、`其时空节点模型`、`其片段模型`
- 片段级效果（`其片段模型*`）：`Audio`、`AudioVolumeFilter`、`AudioFadeFilter`、`AudioLoudnessBalanceFilter`（响度均衡）、`AudioMatrixFilter`、`AudioEffectAdjustFilter`、`ComposerFilter`、`Color`、`ChromaChannel`（色度通道）、`AIMatting`（AI 抠像）、`AutoFillFrame`（自动补帧）、`BrushSticker`（画笔贴纸）
- 资源：`其模型层组件`、`其模型层组件`、`其模型层组件`/`IdParser`、`其模型层组件`
- 其它：`其模型层组件`、`其模型层组件`、`其模型层组件` + `其模型层组件`、`其模型层组件`

#### 1.5.6 边界与合规（**这条要传哲拍板，不由 AI 代决**）

- podspec 的 license 字段**不一致**：`其轨道 UI 组件库` / `其媒体引擎层` 写 MIT，`其编辑语义层` 与
  `其创作 SDKKit` 是自定义 license 块。`其创作 SDKKit` 在该厂商文档里明确是**商务授权产品**（绑 Bundle ID + 合同时长）。
- 因此：**头文件与 JSON 资源可用于接口层/信息架构研究**（读、对照、提炼设计），
  **但把 `.a` / `.framework` 集成进产品属于商用授权范畴**，与 FFmpeg LGPL 那类问题同级，
  **需法务/商务拍板**，本文不给结论。
- 本文所有核验均为**下载后只读静态分析**，未链接、未集成、未运行。


---

### 1.5.7 二进制的静态观察能做到哪一步（本次实测，**含合规边界**）

> 传哲问「能不能根据二进制搞逆向」—— 分级回答：元数据层的静态观察**能做且已做**，
> 反汇编还原实现逻辑**不做**，理由见下表末行与 §1.5.6。

| 手段 | 命令 | 本次实测拿到 | 性质 |
|---|---|---|---|
| 架构 / 体积 | `lipo -info` | `armv7 + x86_64 + arm64`，20 MB | 元数据 |
| 导出符号 | `nm -arch arm64 -gU` | **108 个 OC 类**、**546 个实例变量**、**34 个协议** + C 函数 | 元数据 |
| 字符串 | `strings` | 2604 个候选 selector、`dve_ui_*` 共 18 个 key | 元数据 |
| 资源 | bundle 内 JSON / `Assets.car` | 已读，见 §1.5.4 | 数据 |
| **反汇编 / 反编译还原实现** | `otool -tV` / Hopper / IDA | **未做** | ⚠️ 见下方边界 |

#### 实测拿到什么

**① 108 个类的全清单**（与 147 个公开头文件互补：头文件含 category/protocol，
二进制里还有头文件**未暴露**的类，如 `其缩略图管理器/Loader/Task`、
`其轨道 UI 模型`、`其轨道组件`、`其编辑器组件/RectDrawView/MirrorDrawView`）。

**② 546 个实例变量 = 内部结构**（头文件里完全没有的东西，逐类可查）：

```
其多轨控制器:
  _adjustViewModel  _audioViewModel  _effectViewModel  _filterViewModel
  _mixTypeViewModel _stickerViewModel _textStickerViewModel _videoViewModel
  _trackView  _context

其缩略图管理器:
  _context  _handlers  _loaders  _lock  _operationQueue  _tasks

其关键帧视图模型:  _context  _frame  _isShowKeyFrame  _slot
其轨道 UI 模型:       _layer  _slots  _trackType

其蒙版编辑视图:
  _panGesture/_panHandler  _pinchGesture/_pinchHandler  _rotateGesture/_rotateHandler
  _config  _drawView  _borderView  _label  _delegate
```

**两个直接可用的对照结论**：

- `其多轨控制器` = **一个控制器 + 8 个「按片段类型划分的 ViewModel」**
  （视频 / 音频 / 滤镜 / 特效 / 贴纸 / 文字贴纸 / 调节 / 混合类型）。
  这与 §1.5.4 `color.json` 的**按类型着色**是同一套分类的两种表现 ——
  即**片段类型是轨道 UI 的一等公民**，颜色、ViewModel、单元格三处都按它切。
- `其缩略图管理器` = **队列 + 锁 + 任务表 + 加载器 + 回调处理器**
  （`_operationQueue` / `_lock` / `_tasks` / `_loaders` / `_handlers`）。
  可直接对照我们的 `TimelineThumbnailStore`（并发上限 3、in-flight 去重、LRU 240、失败记账不重试）——
  同一个问题的两种解法，值得逐项比对我们是否漏了「handlers 分层」与「显式锁」。

**③ 配置完整性可自证**：二进制里 `dve_ui_*` 恰好 **18 个**（`dve_ui_color_*` 15 + `dve_ui_layout_*` 3），
与 bundle 里 `color.json` + `layout.json` 的条目数**完全一致**。
→ 说明配置**确实全在外部 JSON**，没藏在代码里；也意味着**看配置不必做逆向，读 JSON 即可**。

#### 边界（**这条要拍板，不由 AI 代决**）

- **不做反汇编 / 反编译 / 实现逻辑还原**。商业 SDK 的 EULA 普遍明令禁止 reverse engineering，
  且二进制集成本身属商用授权范畴（§1.5.6）。此问题与 FFmpeg LGPL 同类，**需法务/商务拍板**。
- 符号表、字符串、资源清单属于对**已合法取得的文件**做元数据分析（等同于 `nm` / `strings` / `lipo`
  这类常规检查），本次用途仅限架构与信息架构研究，**未链接、未集成、未运行、未还原实现**。


## 2. 阿里云 · 短视频 SDK（UGSV）—— **iOS 端**（本节为主体）

> **修订 2026-10-10 22:40**：首版把篇幅给了云剪辑 Web SDK，传哲指出「阿里云应该看 iOS 端」后重写本节。
> 复核结论：**负结论不变**（两个 iOS 仓库我都核过，见 §2.5），但 iOS 端的内容此前确实没做实现已补齐。

### 2.1 官方入口与 iOS 仓库（实测）

- **官方 Demo 页**：`https://help.aliyun.com/zh/apsara-video-sdk/demo-for-mediabox-sdk`
  （MediaBox 音视频 SDK Demo 体验，页面更新 2026-06-16）。原文：MediaBox Demo 是「播放器、短视频和
  直播推流的全链路演示」；**点播场景含「短剧 / 信息流播放 / 沉浸式播放 / 短视频制作」四个入口**。
- **iOS 端仓库（官方页直接给出）**：`https://github.com/aliyunvideo/MONE_demo_opensource_iOS`
  — 实测 **HTTP 200**，170,565 KB，**6674 条目**
- **运行方式（官方页原文）**：iOS 9.0+ / Xcode 13+ / CocoaPods 1.10+，**不支持模拟器**；
  在 `AlivcAIODemo` 目录 `pod install` → 打开 `AlivcAIODemo.xcworkspace`；
  License 文件改名 `license.crt` 放 `AlivcAIODemo` 目录，`Info.plist` 的 `AlivcLicenseKey` 填 License Key。
- 该仓库是**一体化 App**，顶层 5 条产品线：`AlivcPlayerDemo` / **`AlivcUgsvDemo`（短视频）** /
  `AlivcLiveDemo` / `AlivcRtcDemo` + `AUIBaseKits`（公共组件）。
  首页入口 `AIOHomeViewController.m`，卡片原文「**短视频** —— 短视频拍摄、剪辑、特效」（icon `ic_ugc`）。
- **另有独立裁剪仓库** `MediaBox-Demos/amdemos-ios-ugsv`（132,888 KB，5693 条目，MIT），只含 UGSV，
  是官方「短视频 SDK Demo 源码下载」页指向的那份。**两者 UgsvDemo 同源，MONE 版更全**
  （多出模板成片与多轨编辑条，见 §2.4）。
- **SDK 二进制**：`AliVCSDK_ShortVideo.library.zip`（7.11.0），实测 HTTP 200 / 11,123,529 B；
  **需 License**，未授权最多 7 天自测。

### 2.2 iOS 端短视频 Demo 的真实入口（实测源码）

`AlivcUgsvDemo/Class/List/AUIUgsvViewController.m` —— **6 个入口**（原文字符串）：

| # | 入口 | 落点 |
|---|---|---|
| 1 | **视频拍摄** | `AUIVideoRecorder` |
| 2 | **视频编辑** | `AUIVideoEditor` |
| 3 | **视频裁剪** | `AUIVideoCrop`（clipper） |
| 4 | **剪同款** | `AUIUgsvEntranceTypeTemplate` → `openTemplateList` |
| 5 | **视频合拍** | `AUIUgsvEntranceTypeMixRecorder` → `openMixRecorder` |
| 6 | 更多 | `AUIUgsvMoreViewController`（自定义拍摄/编辑/裁剪/合拍/参数） |

### 2.3 iOS 端源码结构（MONE · `AlivcUgsvDemo`，tree API 实测）

```
AlivcUgsvDemo/Class/
├── List/        AUIUgsvViewController（6 入口）· More · Info · OpenModuleHelper
├── Modules/
│   ├── VideoRecorder/  AUIVideoRecorder + Panels{贴纸,滤镜,合拍布局} + Views{底部按钮,
│   │                   倒计时,进度条,倍速,焦距滑杆,顶部按钮,控制层} + Wrapper
│   ├── VideoEditor/    AUIVideoEditor + Menu{Bar,Item,Manager} + Action{Manager,Items}
│   │                   + EditBar{ Video / Caption / Effect / Filter / Sticker /
│   │                       Timeline / **MultiTimeline** }  ← 多轨编辑条
│   │                   + EditBar 二级面板{AudioEffect 变声, Augmentation 画面增强,
│   │                       Caption 字幕, Effect, SpeedChanged 变速, Sticker,
│   │                       Transition 转场, Volume 音量}
│   │                   + Selection{Manager,Object,Preview}  ← 选中管理体系
│   │                   + Play / Export + Utils{Aep 动效, ThumbnailCache, TimelineTitleLoader}
│   ├── VideoCrop/      AUIVideoCrop + Timeline + Export
│   └── VideoTemplate/  List · Preview · Editor · EditBar{Cell,Item,TextInput,
│                       MenuData,MenuItem,PopMenuItem} · Export · Play · Resource  ← 剪同款全套
├── Components/  FilterPicker · MusicPicker(含 PCMLine 波形 + Crop 截取) · PhotoPicker ·
│                StickerPicker · VideoCutter · VideoPreview · MediaPublisher(上传)
├── Base/        ResourceManager(含 Caption 字体/动画/样式模型) · UIKit · Ugsv · Media
└── Resources/   AlivcUgsv.bundle/Theme/DarkMode/{Editor,Recorder,Timeline,Template}
```

### 2.4 面板与能力矩阵（实测文件名）

| 能力 | 类（iOS 端实有） | 备注 |
|---|---|---|
| 音乐 | `AUIMusicPicker` + `AUIMusicPCMLineView` + `AUIMusicCropView` | 列表 + **波形** + 裁剪截取 + 状态机 |
| 滤镜 | `AUIFilterPanel` / `AUIEditorFilterEditBar` | LUT + 动效滤镜 |
| 贴纸 / 特效 | `AUIEditorSelectStickerPanel` / `SelectEffectPanel` | |
| **字幕** | `AUICaptionControllPanel` + `AnimationView` / `BubbleView`（气泡）/ `FlowerView`（花字）/ `InputView` / `StyleView` / `AliyunCaptionFontView` / `AliyunCaptionStyleTempleteView` | **做得最细的一块** |
| 变速 / 音量 / 变声 | `AUISpeedChangedControllPanel` / `AUIVolumePanel` / `AUIAudioEffectPanel` | 变声含萝莉/大叔/KTV/混响/机器人 |
| 画面增强 | `AUIVideoAugmentationPanel` | 亮度/对比度/饱和度/锐度/暗角 |
| 转场 | `AUITransitionControllPanel` + `AUITrackerClipTransitionView` | |
| 时间线 | `AUITimelineView` + `AUIEditorTimelineEditBar` + **`AUIEditorMultiTimelineEditBar`** + `AUIEditorThumbnailCache` + 片段数据 `AUITrackerClipData{start,duration,clipStart,clipEnd,speed,转场}` | 按 **tracker（轨）** 组织 |
| 选中管理 | `AUIEditorSelectionManager` / `SelectionObject` / `SelectionPreview` | 片段选中态独立成体系 |
| 动效（AEP） | `AUIAepHelper` + `AUITrackerClipData+AepHelper` | 阿里云 AEP 动效格式 |
| 拍摄页组件 | `AUIRecorderBottomButtonsView` / `CountDownView`（倒计时）/ `ProgressView`（分段进度）/ `RateSelectView`（倍速）/ `CameraForceView`（焦距）/ `SliderButtonsView` / `HeaderButtonsView` / `ControlView` | 拍摄 UI 组件齐全 |
| **剪同款 / 模板成片** | `AUIVideoTemplate{List,Preview,Editor}` + `EditBar{Cell,Item,EditTextInput,EditMenuData,MenuItem,PopMenuItem}` + `Export` + `Resource` | **MONE 版独有**，amdemos 仓库无；与该厂商「剪同款」同一赛道 |
| 裁剪 / 发布 | `AUIVideoCutter` / `AUICropTimelineView` / `MediaPublisher`（上传点播 + Token + 进度） | 独立 Clipper 分包 |

### 2.5 实测**负结论**（两个 iOS 仓库都核过，结论一致）

对 `amdemos-ios-ugsv`（5693 条目）与 `MONE_demo_opensource_iOS`（6674 条目）分别做文件名级检索：

| 能力 | amdemos-ios-ugsv | MONE（iOS 一体化） | 判定 |
|---|---|---|---|
| `split`（分割） | **0** | **0** | **没有分割 UI** |
| `undo` / `redo` | **0 / 0** | **0 / 0** | **没有撤销重做**（`AUIEditorActionManager` 只有 `doAction:`，无操作栈） |
| `draft`（草稿箱） | **0** | **0** | **开源 UI 里没有草稿箱**（官方文档称支持草稿列表+云同步，源码无对应文件） |
| `copy` / `duplicate`（复制片段） | **0** | **0** | 无 |

> 这不是「核错了仓库」：两个仓库、两种口径都验过。阿里云 iOS 端开源 UI 的片段操作实测只有
> **左右边缘 trim、拖动移动排序、删除、变速、音量、转场**。
> 它是**「录制 + 单层编辑 + 裁剪 + 合拍 + 剪同款 + 上传」**的形态，**不是对标 App那种多轨重编辑器** ——
> 有 `tracker` 多轨数据结构和 `MultiTimelineEditBar`，但 UI 层没长出分割/撤销这些重编辑交互。
> **撤销重做是我们相对它的现成优势**（ADR-0012 已有命令栈与撤销栈线程边界定案），不要反过来对齐它。

### 2.6 云剪辑 Web SDK —— **另一条产品线，不是 iOS 端**（旁支，只看布局）

- 仓库 `https://github.com/aliyunvideo/ICE_WebSDK_demos` ✅ HTTP 200（含 `fe/` `java/` `nodejs/`）；
  Vite + React18 + Vue3 + antd；Java 服务端（Spring Boot，配 AK/SK）。
- **编辑器本体不是 npm 包**：`fe/package.json` 为 `private: true`，SDK 走 CDN
  `https://g.alicdn.com/thor-server/video-editing-websdk/4.13.1/index.js`。
- 界面（官方原文）：左素材面板、中预览（播放控制+倍速）、右 **L/R 双声道电平表**、
  底部多轨时间线（字幕轨/视频轨/音频轨）、顶部「生成为模版/保存/导出为」。
- 与端上 SDK 的区别：端上 = 本地采集+本地编辑+本地导出（**UI 源码可改**，引擎闭源）；
  云剪辑 = **云端 Timeline 描述 + 云端渲染合成**，编辑器 UI 由阿里 CDN 的 JS 全量托管，
  **开源的是 demo 外壳，不是编辑器本身**。
- → **它是阿里云那边唯一有「类对标 App多轨时间线」的产品，但它在 Web，iOS 端没有对应物。**
  参考 UI 布局可以，抄实现没门，**也替代不了 §2.1~2.5 的 iOS 端内容**。

## 3. 三家对照（功能 × 字节 × 阿里云端上 × 我们）

| 能力             | 字节 其创作 SDK                         | 阿里云 UGSV（开源 UI）                                    | ChuanqiCut 现状                         |
| -------------- | ------------------------------------ | -------------------------------------------------- | ------------------------------------- |
| 拍摄面板           | 6 项侧栏可装配 + 模式栏                       | 3 个面板（贴纸/滤镜/合拍布局）                                  | Camera Pod 已立（ADR-0014 iOS 原生栈）       |
| 预览编辑一级入口       | 8 项（可排序/删减/折叠）                       | 6 项菜单（音乐/剪辑/文字/贴纸/滤镜/特效）                           | UIA-032 已重构，9 项可用（RESEARCH-010）       |
| 轨道编辑           | **有**，3 轨 + 8 个底部操作                  | **有多轨数据结构，UI 很薄**（无分割/撤销/复制）                       | UIA-034~036 UIKit 重建 + 037/038 缩略图/缩放 |
| 拆分（split）      | ✅ 底部工具栏一级操作                          | ❌ 源码 0 命中                                          | 待核（RESEARCH-010 §3）                   |
| 撤销/重做          | ✅ 播放控制栏四态 icon                       | ❌ 源码 0 命中                                          | ✅ **ADR-0012 已定案命令栈**（优势）             |
| 草稿箱            | ✅ 有管理/全选/空态                          | ❌ 开源 UI 无                                          | ChuanqiCutDraft Pod 骨架已立（占位）          |
| 转场             | ✅ 0.1~1.1s，片段间 icon 两态               | ✅ 有 model + 应用到全部                                  | 待核                                    |
| 变速             | ✅ **0.1x~10x**（音视频均支持）               | ✅ 有面板                                              | 待核                                    |
| 字幕             | ❌ 未在 UI 标注出现                         | ✅ **最细**（气泡/花字/动画/字体）                              | 待核                                    |
| 画面调节           | ❌ 未出现                                | ✅ `AUIVideoAugmentationPanel`                      | 待核                                    |
| 涂鸦 / 画中画 / 关键帧 | ❌ 未出现（文档无）                           | ❌ 未出现                                              | 待核                                    |
| 面板配置化          | ✅ **JSON + panel_key + 色卡 + 文案 key** | 部分（ResourceManager 模型化）                            | 未做（**最大 gap**）                        |
| 换肤             | ✅ 色卡系统 + 同名 icon 替换                  | ✅ `Theme/DarkMode/{Editor,Recorder,Timeline}` 资源目录 | Theme 令牌已立（UIA-033）                   |


「我们」一列标「待核」的，是本次未开工程核实的项，以 RESEARCH-010 与代码为准，别拿这张表当现状声明。

---

## 4. 可执行建议

**值得抄（按性价比排序）**

1. **面板配置化协议**（该厂商，§1.4）：`Panel_configs/<panel_key>.json` 的 `tabs → subItems` 结构 + 内置/在线两种 ResourceLoader。新增一种素材类型**不改代码、只发 JSON**，天然带多语言、按需下载、客户可替换。我们目前面板是代码写死的（RESEARCH-005 的信息架构还没落到数据层），这是**最大 gap**。建议落到 LIB/Editor 域作为 SPEC 输入。
2. **换皮契约三件套**（该厂商）：同名 icon 替换（带推荐像素尺寸）+ 色卡 Key + 文案 Key，UI 标注页做到「每个可见元素都有唯一 key」。我们已有 Theme 令牌（UIA-033），**缺的是色卡 Key 与文案 Key 的命名规范**——这套规范可以直接照搬命名思路。
3. **编辑动作收口成 ActionItem**（阿里云）：`AUIEditorActionItem` 子类 + `AUIEditorActionManager` 分发，菜单/面板/时间线三处入口共用一条管道。我们已有 Command（ADR-0012），可对照看**是否缺 ActionManager 这一层分发**。
4. **时间线按「tracker = 轨」抽象 + 片段自带 speed/转场/缩略图请求**（阿里云）：`AUITimelineView`/`AUITrackerClipData` 与我们的 UIA-037/038 概念高度对齐，可用来校验我们自己的数据模型有没有漏字段。

**别抄**

- 别把「阿里云没有撤销重做」当成业界常态 —— 那是它的短板，**我们有命令栈，是优势**。
- 别指望从该厂商拿到源码：APK 只能看交互，文档只能看契约，**包必须商务谈**。
- 云剪辑 Web SDK 抄不了实现（编辑器是 CDN 上的闭源 JS），只可看布局。

---

## 5. 未拿到 / 待验证

| 项                                   | 状态                                                                       |
| ----------------------------------- | ------------------------------------------------------------------------ |
| 字节 iOS TestFlight 链接是否有效            | **未验证**（需自行安装 TestFlight 打开）                                             |
| 字节 SDK 最低系统版本                       | 未拿到（该厂商海外品牌 只写 iOS/Android，格式限制页未挖到数值）                                  |
| 字节 RN/Flutter 包是否真的存在               | 未验证（三方评测称只发文档未发包）`[推断]`                                                  |
| 该厂商轨道**缩放手势**、**关键帧 UI**、**片段复制/换序** | 未拿到（UI 标注页未提及）                                                           |
| 阿里云 UGSV 源码**语义级**核验                | 已做到文件名级（tree API 5693 条目）；完整源码未下载（tarball 132 MB 拉取超时 4 min），**未做逐文件阅读** |
| 阿里云「剪同款/模板成片」UI 细节                  | 只确认 MONE 仓库有 `VideoTemplate/` 目录，**未展开**                                 |
| 通义万相相关视频编辑 demo                     | 未拿到，未检索到官方入口                                                             |

---

## 6. 证据清单

**字节**

- 产品概览 / 交付门槛：`https://该厂商云服务.com/docs/3019/1535822`
- 基础拍摄剪辑：`https://该厂商云服务.com/docs/6839/131320`、功能清单 `https://该厂商云服务.com/docs/6839/1509164`
- Demo 体验页（含 APK 直链）：`https://该厂商云服务.com/docs/6839/1544704`
- 剪同款：`https://docs.该厂商云服务.com/docs/6839/1582479`；高光成片：`https://www.该厂商云服务.com/docs/IntelligentVideoCreationSDK/Highlightfilm`
- UI 标注：拍摄 `https://该厂商云服务.com/docs/6408/1582522`、轨道编辑 `https://www.该厂商云服务.com/docs/6464/1582524`、草稿箱 `https://该厂商云服务.com/docs/6839/1507953`、相册 `https://该厂商云服务.com/docs/6470/2175027`、音乐 `https://该厂商云服务.com/docs/6839/1582527`、基础组件 `https://www.该厂商云服务.com/docs/6839/1582521`
- 交付清单：`https://www.该厂商云服务.com/docs/6839/1521798`；包大小：`https://docs.该厂商云服务.com/docs/6839/2174984`
- **海外迂回（中文页抓不到时用）**：`https://docs.byteplus.com/en/docs/video-editor-sdk/preview-editor-panels-and-configurations`、`.../track-editor-panels-and-configurations`、`.../docs-android-resources-import-and-configuration`

**阿里云**

- 短视频 SDK 产品文档：`https://help.aliyun.com/zh/vod/developer-reference/short-video-sdk`
- Demo 源码下载页：`https://help.aliyun.com/zh/vod/developer-reference/short-video-sdk-demo-examples`
- SDK 下载页（7.11.0）：`https://help.aliyun.com/zh/vod/developer-reference/download-short-video-sdk`
- iOS 源码仓库：`https://github.com/MediaBox-Demos/amdemos-ios-ugsv`
- MONE 一体化 Demo（含模板成片）：`https://github.com/aliyunvideo/MONE_demo_opensource_iOS`
- 云剪辑 Web SDK Demo：`https://github.com/aliyunvideo/ICE_WebSDK_demos`、文档 `https://help.aliyun.com/zh/ims/developer-reference/the-demo-experience-2`

---

## 7. 下游建议

- 落到 **LIB/Editor 域**：面板配置化协议（§4.1）需新开 SPEC，建议先出提案交集成机，不直接开工。
- 落到 **UIA 域**：色卡 Key / 文案 Key 命名规范（§4.2），可并入 UIA-033 Theme 令牌的后续卡。
- 与 RESEARCH-010（编辑功能现状核验）合并看：本文 §3 对照表里「待核」项应回填到 RESEARCH-010 的能力清单。
- **落地输入见 §8**：按 B0~B8 逐批给设计输入（22 条，每条挂实证来源），末列 **3 项待传哲拍板**
  （面板配置化做不做 / slot 概念引入时机 / 草稿箱是否提前到 B3）。**§8 不改批次顺序**，顺序仍以 ADR-0034 为准。
---

## 8. 对 B0~B8 的落地输入（基于本次竞品实证）

> **本节不改批次顺序**（顺序由 ADR-0034 / RESEARCH-010 §5 拍板，本节只给**每个批次内部的设计输入**）。
> 每条都标了实证来源；标 `[待拍板]` 的是会改变既有设计前提的项，需传哲裁决后才动。
> 纪律：这些是**设计参考**，不是验收阈值；涉及性能的数字一律无实测，不进 baselines。

### 8.1 B0 渲染地基 / 属性系统（RENDER-001 + MODEL-003 + SHADER-001）

| # | 输入 | 实证来源 | 为什么现在就得定 |
|---|---|---|---|
| 1 | **EffectBinding 的 key 空间按「片段类型」分区**，不要做成扁平参数表 | `其多轨控制器` 的 8 个类型 ViewModel（video/audio/filter/effect/sticker/textSticker/adjust/mixType）；`color.json` 按类型着色 | B7 加滤镜/调参/转场时若 key 是扁平的，会变成"往一张大表里加字段"，届时必重构 |
| 2 | **引入 slot（槽）概念**：轨道 = `layer + slots + trackType` | `其轨道 UI 模型{_layer, _slots, _trackType}`（IVAR 级） | 我们现在的模型是「track + clip」两层，**缺 slot 这一层**；B6 贴纸/文字、B8 关键帧都要挂在 slot 上（该厂商关键帧就是 `_slot + _frame`），现在不预留，B6/B8 必返工 |
| 3 | **属性动画接口现在就留**，即使 B8 才实现 | `其关键帧视图模型{_context,_frame,_isShowKeyFrame,_slot}` | 关键帧是「slot 上的 (frame → value) 序列」。EffectBinding 若不含插值接口，B8 要改的是**地基**而不是加功能 —— 这正是 ADR-0034 要避免的 |
| 4 | **RenderGraph 预留 mask / alpha 输入槽位** | `其编辑器组件*` 共 16 个类、5 种绘制（circle/line/rect/mirror/draw）、`其媒体上下文+Blend` | 蒙版与混合不是"一个开关"，B8 需要额外输入槽；现在留个空槽比届时改 RenderGraph 接口便宜得多 |

### 8.2 B1 模型层命令（Split / RemoveClip / 左缘裁剪）

| # | 输入 | 实证来源 | 说明 |
|---|---|---|---|
| 5 | **UI 侧建 `EditorAction` 分发层**：每个动作封装为 item（含 `canExecute` 可用性判定），菜单 / 面板 / 时间线三处入口共用一条管道 | 阿里云 `AUIEditorActionItem` 子类 + `AUIEditorActionManager` | 我们已有 Command 与命令栈（ADR-0012），**缺的是 UI 侧的动作抽象层**。补上后，"这个功能目前不可用"能由 `canExecute` 明确表达，而不是 `enabled:false` + 空闭包 —— 直接治 RESEARCH-010 §2.1 / P99 那个"绿而空"的根因 |
| 6 | **Split 的撤销纳入 B1 验收**，不只是"能切" | 阿里云开源 UI **实测无 split / 无 undo·redo**（两仓库文件名级核验） | 撤销重做是我们相对阿里云的现成优势，别只做正向命令 |
| 7 | 片段数据字段对照检查表：`start / duration / clipStart / clipEnd / speed / 转场` | 阿里云 `AUITrackerClipData` | 逐项核我们的 Clip 是否有 **clipStart/clipEnd（源内裁剪区间）** 与 speed；缺了 B5 音量、B7 变速都要补字段 |

### 8.3 B2 音频地基

| # | 输入 | 实证来源 | 说明 |
|---|---|---|---|
| 8 | **混音时顺带产出波形峰值数组**给 UI 用，别等 B5 再补 | `其轨道组件` + `其轨道组件` + `color.json` 三种波形色（default `0xECC66B` / sound `0xED8ACE` / recorder `0x12882E`） | 波形是该厂商音频 UI 的一等公民，且**按来源分色**。B2 不做，B5 会被迫在 UI 层重新解码一遍 |
| 9 | **音量 / 淡入淡出 / 响度均衡是三种独立 filter**，不是音量参数的一个字段 | `其模型层组件` / `AudioFadeFilter` / `AudioLoudnessBalanceFilter` / `AudioMatrixFilter` | 该厂商把音频效果做成可叠加的 segment filter 链，命名即分类 |
| 10 | 音频片段的**裁剪手势与视频 trim 是两套**（波形上的区间选择 vs 边缘拖拽） | 阿里云 `AUIMusicCropView` 独立于 `AUITrackerClipView` | 别复用视频 trim 手势，UI 手感会不对 |

### 8.4 B3 工程持久化

| # | 输入 | 实证来源 | 说明 |
|---|---|---|---|
| 11 | 项目文件 schema 要能表达 **slot**（见 #2）与 **filter 链**（见 #9、#15） | `其片段模型*Filter` 可叠加、有时序 | 序列化往返一致性验收时，把"多个 filter 叠加后的顺序"列为用例 |
| 12 | 草稿箱：该厂商有（`eo_draft_*` 管理/全选/空态），阿里云开源 UI **没有** | 两侧实测对照 | 我们有 `ChuanqiCutDraft` Pod 骨架（占位）；B3 若不做，**二期补会动 schema**，建议 B3 一并带上最小草稿（存/取/删/空态四态） |

### 8.5 B4 导出闭环（第一个可见出口）

| # | 输入 | 实证来源 | 说明 |
|---|---|---|---|
| 13 | 验收标准强化：同一 Timeline 描述，**预览与导出的属性解析必须是同一条路径**（不只是"像素一致"） | 字节 NLE 模型、阿里云云端 Timeline 都是单一描述驱动两种输出；我们红线 #9 同义 | 不改变现有结论，只是把"一致"从结果一致收紧为**路径一致**，防止出现第二条解析路径（ADR-0014 教训） |
| 14 | 导出页参照字节 `其导出 UI 模块`（交付清单里明确给了示例代码） | 该厂商 iOS 交付清单含 `其导出 UI 模块` 实现 | 我们拿不到它的源码，但**它存在**意味着导出页是独立可换皮模块 —— 我们的导出面板也应做成独立可替换组件 |

### 8.6 B5 音频可见能力

- 15'. 字节 BGM 轨：独立背景色 + 波形 + **可截断**；原声开关 + 音量（UI 有独立 icon 与文案 key）。
  阿里云：音乐列表 + 波形 + 裁剪截取（`AUIMusicCropView`）。两侧一致 → **BGM 的"截取区间"是独立数据**，不是整段引用。

### 8.7 B6 文字与贴纸

| # | 输入 | 实证来源 | 说明 |
|---|---|---|---|
| 15 | **文字样式拆成四个正交维度**：内容(text) / 样式模板(styleTemplate) / 动画(animation) / 字体(font)，可组合 | 阿里云 `AUICaptionAnimationModel` / `AUICaptionFontModel` / `AUICaptionStyleTempleteModel` 三个独立 model + `AnimationView`(15 种入场动画) / `BubbleView`(气泡) / `FlowerView`(花字) | 阿里云字幕是它做得最细的一块，这套四维拆分可直接抄信息架构 |
| 16 | **变换交互 = 手势 与 handler 分离**，handler 可跨对象复用 | `其蒙版编辑视图`：`_panGesture/_panHandler` + `_pinchGesture/_pinchHandler` + `_rotateGesture/_rotateHandler` | B6 建变换 handler 时按此分层，B8 蒙版、以及 macOS 端缩放旋转可直接复用同一套 handler |

### 8.8 B7 视觉效果

| # | 输入 | 实证来源 | 说明 |
|---|---|---|---|
| 17 | 效果统一抽象为**可叠加的 segment filter 链**（有时序），而非"每个效果一个开关" | `其模型层组件` / `ChromaChannel` / `Color` / `AudioEffectAdjustFilter` … | 与 #1 的 key 分区配合：**类型决定挂在哪个分区，filter 链决定叠加顺序** |
| 18 | UI 上**按效果类型扩展单元格类型**，而不是加一个通用"效果列表" | 8 个类型 ViewModel + `color.json` 按类型着色 | 滤镜紫 / 调节绿 / 特效粉 / 贴纸蓝 / 文字黄 —— 分类即 UI 分类 |

### 8.9 B8 进阶

- 该厂商实证清单（可直接作为 B8 的功能清单底稿）：
  **关键帧** `其轨道组件{View,ViewModel,Item,Protocol}`（`slot+frame`）、
  **蒙版** `其编辑器组件*`：circle / line / rect / mirror / draw 五种绘制 + 三套手势、
  **混合** `其媒体上下文+Blend`、**抠像** `其模型层组件`、**自动补帧** `其模型层组件`、
  **画笔贴纸** `其模型层组件`。
- 阿里云侧同层只有转场（`AUITransitionControllPanel`）与变声，**没有关键帧/蒙版/抠像** —— 这块的参照物只有该厂商。

### 8.10 横切（对所有批次，建议优先做一条）

| # | 输入 | 实证来源 | 建议时机 |
|---|---|---|---|
| 19 | **UI 配置表：色卡 Key + 尺寸 Key**（把颜色/尺寸从代码搬到表） | 字节 `color.json`（15 项）+ `layout.json`（按钮 `{42,42}`、每帧宽 `50`）；阿里云 `Theme/DarkMode/{Editor,Recorder,Timeline}` 资源目录 | **B4 之前**（B4 动 UI 最多）。我们有 UIA-033 Theme 令牌的基础，可并入，成本低 |
| 20 | **轨道按片段类型着色**（先埋颜色映射，不需要能力到位） | `color.json` 逐类型配色 | UIA-034~036 时间线重建时顺手做；能力没到位也能先渲染出分类色 |
| 21 | **缩略图管理器补两项**：handlers 分层 + 显式锁 | `其缩略图管理器{_operationQueue,_lock,_tasks,_loaders,_handlers}` | UIA-037 已编码完**未验证**（挂池 [6]），验证时一并核这三项我们自己缺的（我们现有：并发上限 3 / in-flight 去重 / LRU 240 / 失败记账） |
| 22 | `[待拍板]` 是否引入**面板配置化**（一份配置描述面板的分组/顺序/图标/多语言） | 字节 `Panel_configs/*.json`（tabs→subItems） | 该厂商靠它做到"2~3 周接入 + 换皮"。**但它是为多客户换皮设计的，我们目前是单一产品**，收益与成本需传哲判断 —— 若做，建议在 B6（文字/贴纸面板变多）之前定，否则面板越加越硬编码 |

### 8.11 明确不抄

- **不抄阿里云"没有撤销重做"** —— 那是它的短板，我们有 ADR-0012 命令栈，是优势。
- **不照搬该厂商的 ResourceLoader / 在线素材下发体系** —— 那套是为「多客户 + 素材运营」设计的，
  我们目前没有素材运营体系，搬进来是纯成本（面板配置化同理，见 #22 待拍板）。
- **不因为该厂商有关键帧就提前做 B8** —— 顺序已定（ADR-0034），本节只要求 B0 **预留接口**，不是提前实现。

### 8.12 需要传哲拍板的三件事

1. **#22 面板配置化做不做**（会改变 UI 层的组织方式，影响 B6 及之后所有面板）。
2. **#2 slot 概念何时引入** —— 我建议 B0/B1 就引入（否则 B6/B8 返工），但这会略微增加 B0 的设计量。
3. **#12 草稿箱是否提前到 B3** —— 现在 `ChuanqiCutDraft` 是占位 Pod，若二期再补会动 schema。

