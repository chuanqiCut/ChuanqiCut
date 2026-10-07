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

  # ---- 2) 头文件并入源码树（与磁盘布局一致，2026-10-07 传哲：看代码方便）----
  #    core/include 并到 core 组下与 src 平级；pal/apple 的头与 .mm 混排。
  #    全部为导航器引用（不进 headermap/编译——声明走 private_header_files）。
  engine = project.objects.find { |o| o.isa == 'PBXGroup' && o.name == 'ChuanqiCutEngine' }
  added = 0
  if engine
    # 清理旧版独立分组（历次形态）
    ['core/include（头文件，只读浏览）', 'core/include'].each do |old_name|
      stale = project.objects.find { |o| o.isa == 'PBXGroup' && o.parent&.name == 'ChuanqiCutEngine' && o.display_name == old_name }
      # 只删「顶层游离」的旧组：其父是 Engine 组本身且不含 src 子组（新版并入 core/src 树，父不同）
      next unless stale
      next if stale.children.any? { |c| c.isa == 'PBXGroup' && c.display_name == 'src' }
      stale.remove_from_project
    end

    ensure_group = lambda do |parent, name|
      parent.children.find { |c| c.isa == 'PBXGroup' && c.display_name == name } ||
        parent.new_group(name)
    end
    add_tree = lambda do |group, dir|
      Pathname.new(dir).children.sort.each do |child|
        if child.directory?
          add_tree.call(ensure_group.call(group, child.basename.to_s), child.to_s)
        elsif child.extname == '.h'
          exists = group.children.any? do |c|
            c.isa == 'PBXFileReference' && c.real_path.exist? && c.real_path.to_s == child.to_s
          end
          next if exists
          ref = group.new_file(child.to_s)
          ref.source_tree = 'SOURCE_ROOT'
          ref.path = child.relative_path_from(project.path.dirname).to_s
          added += 1
        end
      end
    end
    core_group = ensure_group.call(engine, 'core')
    include_group = ensure_group.call(core_group, 'include')
    add_tree.call(include_group, File.join(repo_root, 'engine/core/include'))
    pal_apple = ensure_group.call(ensure_group.call(engine, 'pal'), 'apple')
    add_tree.call(pal_apple, File.join(repo_root, 'engine/pal/apple'))
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
      # 与 core/include 树同款：SOURCE_ROOT（=Pods 目录）相对路径，须带上溯前缀
      ref.path = Pathname.new(File.join(repo_root, rel)).relative_path_from(project.path.dirname).to_s
      added += 1
    end
  end

  Pod::UI.puts "[pods_post_install] docs 引用删除 #{removed} 条；引擎头文件条目 #{added} 条。"
end
