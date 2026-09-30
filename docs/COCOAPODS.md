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

### 4.1 本机现状（2026-09-30 实测，含一次结论修正）

系统 Ruby 是 macOS 自带的 **2.6.10**（`/usr/bin/ruby`），没有 Homebrew / rbenv / rvm。

**第一版结论（错的，保留以示警示）**：曾判断"环境不允许编译 gem 原生扩展"。
依据是 `gem install --user-install cocoapods` 连续 5 次失败，全部卡在：

```
ERROR: Failed to build gem native extension.
    current directory: ~/.gem/ruby/2.6.0/gems/nkf-0.3.0/ext/nkf
    creating Makefile
    Operation not permitted @ apply2files - ./siteconf...rb
```

**修正后真因**：不是"不能编译原生扩展"，也不是 Ruby 2.6 太老 ——
是 **`~/.gem` 这个安装路径下的权限限制**。把安装目录换掉就过了：

```bash
gem install --install-dir /tmp/cqgems cocoapods --no-document
# → Successfully installed nkf-0.3.0   ← 同样的 gem、同样的 Ruby 2.6，编译成功
```

教训：现象（`Operation not permitted`）看起来像"能力被禁"，实际是**某个具体路径**被禁。
排查时应先换路径做对照实验，不要直接上升到"环境不支持"。

**但换路径只解决了第一层**。第二层是 **Ruby 2.6 确实太老**（这一条是传哲指出后
才查实的，我上一版判断"Ruby 升级没必要"是错的）：

```
ERROR: Error installing cocoapods:
    ffi requires Ruby version >= 3.0, < 4.1.dev. The current ruby version is 2.6.10.210.
    drb requires ruby version >= 2.7.0
```

即：CocoaPods 依赖链上的 `ffi`（要 Ruby ≥ 3.0）与 `drb`（要 Ruby ≥ 2.7）都装不上。
**结论：Ruby 升级是必要条件**（配合可用的安装路径）。

### 4.1.1 Ruby 升级这条路也不通（本机 Intel Mac）

- `brew` 官方安装脚本：**只支持 Apple Silicon**
  （`Homebrew on macOS is only supported on Apple Silicon processors!`）
- 手动 `git clone` brew 到 `~/.homebrew` 后再装 ruby，brew 自己给出结论：

  ```
  If the biggest companies in the world cannot support macOS Intel x86_64
  any longer, sadly neither can we.
  Homebrew no longer builds bottles for this configuration.
  Consider MacPorts, which provides binary packages for this macOS version.
  This is a Tier 3 configuration.
  ```

  即 Intel Mac 已无预编译包，只能源码编译（数十分钟），且本机再次撞上同样的
  `Operation not permitted @ apply2files`（这次在 `~/.homebrew/var`）。

**因此本仓库的 podspec 至今未经过 `pod lib lint` 验证**，只做了 `ruby -c` 语法检查。
这是当前唯一的验证缺口，见 §6。

另：rubygems.org 在本机访问不稳定（502 / FetchError），可换镜像源：

```bash
gem install --install-dir /tmp/cqgems cocoapods --no-document \
    --clear-sources --source https://mirrors.tuna.tsinghua.edu.cn/rubygems/
```

装到自定义目录后需把 bin 加进 PATH：`export PATH="/tmp/cqgems/bin:$PATH"`
（`/tmp` 会被系统清理，长期使用应换成稳定路径，如 `~/.local/cqgems`）。

### 4.2 建议的安装方式（在终端手动执行）

本机是 Intel Mac，Homebrew 已不再提供 Intel bottles（§4.1.1），所以：

```bash
# 方案 A（本机推荐）：MacPorts —— 仍为 Intel 提供二进制包
#   从 https://www.macports.org/install.php 装 pkg 后：
sudo port install ruby33        # 或 ruby32
sudo port install rb-cocoapods  # 或直接：sudo gem install cocoapods

# 方案 B：Apple Silicon 机器上用 Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install ruby
gem install cocoapods --no-document
```

装好 Ruby（≥ 3.0）后，若仍走用户级 gem 安装，**避开 `~/.gem`**（§4.1 的路径问题）：

```bash
gem install --install-dir "$HOME/.local/cqgems" cocoapods --no-document
echo 'export GEM_HOME="$HOME/.local/cqgems"' >> ~/.zshrc
echo 'export PATH="$HOME/.local/cqgems/bin:$PATH"' >> ~/.zshrc
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

## 6. 当前验证缺口（必须补上）

| 项 | 状态 |
|---|---|
| `ruby -c ChuanqiCut.podspec` | ✅ 语法通过 |
| `pod lib lint` | ❌ **未做** —— 本机 CocoaPods 装不上（§4） |
| `pod install`（App 工程） | ❌ **未做** —— 还没有 Xcode 工程（UIA-001 才建） |
| Swift 绑定（SPM） | ✅ `swift test` 7/7、`run_smoke.sh` PASSED |

有 CocoaPods 环境后，第一件事应该跑：

```bash
pod lib lint ChuanqiCut.podspec --allow-warnings --verbose
```

`pod lib lint` 会临时建工程真编译，能暴露 podspec 里 subspec 路径、
C++ 设置、框架声明的问题 —— 现在这些都只是"看着对"，没有机器验证。
按项目纪律：**没过 lint 就不能说 CocoaPods 集成完成**。
