# ChuanqiCut — Ruby 工具链（CocoaPods）版本锁定
#
# 为什么用 Bundler（而不是 `gem install cocoapods`）：
#   CocoaPods 官方就推荐这么做（guides.cocoapods.org/using/a-gemfile.html）——
#   Gemfile.lock 让所有人、所有分支、CI 用的 CocoaPods 版本完全一致。
#   装好之后请一律用 `bundle exec pod ...`，**不要**用裸 `pod`
#   （裸 pod 会绕过本锁定，去用系统里最新的那个版本）。
#
# ⚠️ 本机的特殊约束（2026-09-30 实测，见 docs/COCOAPODS.md §4）：
#   系统 Ruby 是 macOS 自带的 **2.6.10**。CocoaPods 依赖链上有几个 gem 的新版本
#   已经不支持它：
#       ffi           要求 Ruby >= 3.0
#       drb           要求 Ruby >= 2.7
#       activesupport 7.x 依赖 drb 2.x（于是也要求 >= 2.7）
#   解法来自 CocoaPods 官方 issue #12145：**先把这些传递依赖锁到仍支持 Ruby 2.6
#   的版本**，再装 CocoaPods。下面四行就是这个组合，删任何一行都可能装不上。
#
# 本组合已在 Ruby 2.6.10 + macOS 15.4 (Intel) 验证通过。
# 将来升级 Ruby 到 3.x 后，可以去掉 drb / activesupport / ffi 的硬锁。

# 源：本机访问 rubygems.org 会 502，用清华镜像。
# 如果你的网络能直连 rubygems.org，改回 'https://rubygems.org' 即可。
source 'https://mirrors.tuna.tsinghua.edu.cn/rubygems/'

gem 'ffi', '1.15.5'             # 最后一个支持 Ruby 2.6 的版本之一
gem 'drb', '2.0.6'              # 2.1+ 要求 Ruby >= 2.7
gem 'i18n', '1.14.6'            # 1.15+ 要求 Ruby >= 3.1（activesupport 会拉它）
gem 'activesupport', '6.1.7.7'  # 7.x 会拉进 drb 2.x，与上面的锁冲突
gem 'cocoapods', '1.15.2'
