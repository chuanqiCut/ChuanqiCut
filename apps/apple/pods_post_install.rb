# Pods 导航器整理（2026-10-07，传哲拍板要的两件事）：
#   1. 删掉 CocoaPods 自动文档探测塞进来的 docs/** 引用（该行为无开关，1.17 实证）；
#   2. 给 ChuanqiCutEngine 补头文件导航条目（1.17 对 private 头不建条目，实证）。
# 均为**导航器引用**操作，不进编译（头文件编译走 HEADER_SEARCH_PATHS，声明为
# private_header_files；与系统头重名的 7 个头已改名，headermap 劫持源清零）。
# 双 Podfile 共享：require_relative '../pods_post_install' + pods_post_install(installer)。

require 'xcodeproj'

def pods_post_install(installer)
  project = installer.pods_project
  return unless project

  repo_root = File.expand_path('../../../../', installer.sandbox.root) # Pods → ios → apple → apps → 根

  # ---- 1) 删 docs/** 引用 ----
  removed = 0
  project.files.dup.each do |f|
    next unless f.path&.start_with?('docs/')
    f.remove_from_project
    removed += 1
  end

  # ---- 2) ChuanqiCutEngine 头文件树（镜像 core/include 目录结构） ----
  engine = project.objects.find { |o| o.isa == 'PBXGroup' && o.name == 'ChuanqiCutEngine' }
  added = 0
  if engine
    old = engine.children.find { |c| c.isa == 'PBXGroup' && c.display_name == 'core/include' }
    old&.remove_from_project
    root_group = engine.new_group('core/include')
    build_tree = lambda do |dir, group|
      Pathname.new(dir).children.sort.each do |child|
        if child.directory?
          build_tree.call(child, group.new_group(child.basename.to_s))
        elsif child.extname == ".h"
          ref = group.new_file(child.to_s)
          ref.source_tree = 'SOURCE_ROOT'
          ref.path = child.relative_path_from(project.path.dirname).to_s
          added += 1
        end
      end
    end
    build_tree.call(File.join(repo_root, 'engine/core/include'), root_group)
  end

  # ---- 3) CChuanqiCut 模块文件补录（cq_sdk.h/module.modulemap 声明进了编译但
  #         1.17 不生成导航条目；shim.c 已在 source_files 有条目）----
  cmod = project.objects.find { |o| o.isa == 'PBXGroup' && o.display_name == 'CChuanqiCut' }
  if cmod
    module_files = {
      'cq_sdk.h'         => 'engine/bindings/swift/Sources/CChuanqiCut/include/cq_sdk.h',
      'module.modulemap' => 'engine/bindings/swift/Sources/CChuanqiCut/include/module.modulemap',
    }
    module_files.each do |disp, rel|
      next if cmod.children.any? { |c| c.display_name == disp }
      ref = cmod.new_file(File.join(repo_root, rel))
      ref.source_tree = 'SOURCE_ROOT'
      ref.path = rel
      added += 1
    end
  end

  Pod::UI.puts "[pods_post_install] docs 引用删除 #{removed} 条；引擎头文件条目 #{added} 条。"
end
