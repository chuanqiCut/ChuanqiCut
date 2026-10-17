# ChuanqiCutDraft.podspec — 草稿域 Pod 骨架（ADR-0031 阶段 5，INFRA-020）
#
# 骨架占位：功能压在 PROJ-001（项目序列化，core/src/project/ 零实现）上，
# PROJ-001 落地后填肉（PROJ-005 草稿箱 / UIA-029 草稿箱页面）。
# **暂不进任何 Podfile**（无消费者）；首个功能落地时再接线并加依赖。

Pod::Spec.new do |s|
  s.name          = 'ChuanqiCutDraft'
  s.version       = '0.1.0'
  s.summary       = 'ChuanqiCut 草稿域骨架（PROJ-001 落地后填肉）'
  s.homepage      = 'https://REPLACE_ME.invalid/ChuanqiCut'
  s.source        = { :git => ENV.fetch('CQ_POD_SOURCE_GIT',
                                        'https://REPLACE_ME.invalid/ChuanqiCutDraft.git'),
                      :tag => s.version.to_s }
  s.license       = { :type => 'Proprietary', :text => 'License not finalized. See ADR-0010.' }
  s.author        = { 'zhuning' => 'REPLACE_ME.invalid' }

  s.ios.deployment_target = '16.0'
  s.osx.deployment_target = '15.4'
  s.swift_version  = '6.1'

  s.source_files = 'Sources/ChuanqiCutDraft/**/*.swift'
end
