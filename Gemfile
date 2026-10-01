# ChuanqiCut — Ruby 工具链（CocoaPods）
#
# 为什么用 Bundler（而不是裸 `gem install cocoapods`）：
#   CocoaPods 是 Ruby 程序，依赖树容易随系统升级漂移。Bundler 用 Gemfile.lock
#   把版本钉住，让所有人、所有分支、CI 用同一套。装好后一律用：
#       bundle exec pod ...
#   不要直接跑 `pod`（会绕过本锁定）。
#
# 源：本机访问 rubygems.org 会 502，用清华镜像。
#   若你的网络可直连，改回 'https://rubygems.org' 即可。
source 'https://mirrors.tuna.tsinghua.edu.cn/rubygems/'

# 不锁死传递依赖（ffi / drb / activesupport ...）：那是为了兼容旧的
# 系统 Ruby 2.6 才加的临时手段，现代 Ruby 下不需要，且会阻碍安全更新。
gem 'cocoapods'
