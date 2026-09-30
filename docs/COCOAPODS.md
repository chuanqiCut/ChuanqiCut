# CocoaPods 集成（SDK 层）与 SwiftPM 共存策略

> 建立日期：2026-09-30
> 范围：`ChuanqiCut.podspec`（SDK 层）、`apps/apple/Podfile`（App 依赖）、
> 与 `bindings/swift/Package.swift`（SPM）的边界划分。

## 1. 为什么 SDK 层走 CocoaPods，而不是 SPM

| 需求 | CocoaPods | SwiftPM |
|---|---|---|
| vendored 二进制（XCFramework） | `vendored_frameworks`，成熟 | `binaryTarget` 可用，但静态库链接要显式 `linkerSettings`（BIND-002 踩过） |
| C++ 编译设置（C++20、禁异常、禁 RTTI） | `pod_target_xcconfig` 直接写 | 需要 `cSettings`/`cxxSettings`，表达力弱 |
| 按平台分框架（如 IOSurface 仅 macOS） | `ss.osx.frameworks` | 需要手写条件 |
| 系统框架依赖声明 | `frameworks` | `linkerSettings.linkedFramework` |

结论：**SDK 层用 CocoaPods，UI 层用 SPM**。二者在 Xcode 里可共存。

## 2. 两种集成模式（subspec）

```ruby
pod 'ChuanqiCut', :path => '../..'          # 默认 Binary
pod 'ChuanqiCut/Source', :path => '../..'   # 源码模式
```

| subspec | 内容 | 适用场景 |
|---|---|---|
| `Binary`（默认） | `bindings/swift/Frameworks/ChuanqiCut.xcframework` + Swift 绑定源码 | 日常开发；不编译 C++ |
| `Source` | 现场编译 `core/src/**/*.cpp` + `pal/apple/**/*.mm` | 调试内核 / 无预构建产物 |
| `Swift` / `CBridge` | 绑定层与 C module 桥接 | 由上面两者依赖，一般不直接引 |

### Binary 模式前置

```bash
tools/build/build_core_apple.sh --config=Release
bindings/swift/prepare.sh     # 把 xcframework 拷到 bindings/swift/Frameworks/
```

⚠️ `bindings/swift/Frameworks/` 是**构建产物**（`.gitignore` 已忽略），
远端分发时需 CI 先生成再打包。

## 3. SPM 与 CocoaPods 共存

**可以共存**：Xcode 工程同时支持 Swift Package Dependencies 和 CocoaPods。

**但有一条硬规矩**：

> ⚠️ **ChuanqiCut 不要同时在两边引入**。
> 同一份 `Sources/ChuanqiCut/**/*.swift` 会被各编一次，出现重复符号
> （`duplicate symbol ... in ChuanqiCut(Session.o)` 之类）。

推荐组合：

| 层 | 方式 |
|---|---|
| ChuanqiCut SDK（内核 + Swift 绑定） | **CocoaPods**（本 podspec） |
| UI 层纯 Swift 三方库 | **SPM**（Xcode → Package Dependencies） |
| UI 层含二进制/OC 的库 | CocoaPods（与 SDK 同一 Podfile） |

如果某个团队坚持 SDK 也走 SPM，那就**不要**在 Podfile 里引 `ChuanqiCut`，
改用 `bindings/swift` 的 Package.swift —— 二选一，不要并存。

## 4. 环境准备

### 4.1 本机现状（2026-09-30 实测）

系统 Ruby 是 macOS 自带的 **2.6.10**（`/usr/bin/ruby`），没有 Homebrew / rbenv / rvm。

尝试用用户级安装 `gem install --user-install cocoapods` **失败了 5 次**，
全部卡在同一个点：

```
ERROR: Failed to build gem native extension.
    current directory: ~/.gem/ruby/2.6.0/gems/nkf-0.3.0/ext/nkf
    creating Makefile
    Operation not permitted @ apply2files - ./siteconf...rb
```

- 试过最新版、1.15.2、1.11.3，以及单独装 nkf-0.2.0 —— 都在编译原生扩展这一步失败。
- 根因是**当前执行环境不允许编译 gem 原生扩展**（`nkf` 的 C 扩展），
  不是 CocoaPods 本身的问题。
- 也因此：**本仓库的 podspec 尚未经过 `pod lib lint` 验证**，
  只做了 `ruby -c` 语法检查。

### 4.2 建议的安装方式（在终端手动执行）

优先选一条，不要混用：

```bash
# 方案 A（推荐）：装 Homebrew + 独立 Ruby，绕开系统 Ruby 2.6
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install ruby
echo 'export PATH="/opt/homebrew/opt/ruby/bin:$PATH"' >> ~/.zshrc   # Intel Mac 是 /usr/local/opt/ruby
gem install cocoapods --no-document

# 方案 B：继续用系统 Ruby（不推荐，2.6 太老）
sudo gem install cocoapods --no-document
```

若用用户级安装（`--user-install`），记得把 gem 的 bin 目录加进 PATH：

```bash
echo 'export PATH="$HOME/.gem/ruby/2.6.0/bin:$PATH"' >> ~/.zshrc
```

### 4.3 装好之后的验证

```bash
pod --version
pod lib lint ChuanqiCut.podspec --allow-warnings --verbose
```

`pod lib lint` 会临时建一个工程编译验证，能真正检验 podspec 是否正确
（当前环境跑不了，见 4.1）。

## 5. 待定项（发布前必须落实）

| 项 | 现状 | 谁拍板 |
|---|---|---|
| **License** | podspec 里是 `Proprietary` 占位。FFmpeg LGPL 静态链接处置未定（目标文件归档 / 商业授权 / 动态链接 / 不接入 FFmpeg） | owner + 法务（见 ADR-0010） |
| `s.homepage` / `s.source` | 仓库**没有 git remote**，用 `REPLACE_ME.invalid` 占位 | owner |
| `s.author` | 占位 | owner |
| XCFramework 分发 | 产物不入库，需 CI 生成后随 pod 发布 | 与依赖治理一起定（ADR-0008） |

⚠️ 这几项都**故意没有编造**（版本号/URL 凭印象写是本项目踩过的坑，见 pitfalls E6）。
