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

  # ---- 2) core 按模块混排（头文件快捷方式与实现同组，2026-10-07 传哲拍板）----
  #    磁盘保持 include/src 分离（SDK 惯例：公开头=消费者命名空间）；导航器为虚拟视图：
  #    core/<模块> 组 = include/cq/<模块>/**.h + core/src/<模块>/**.cpp，顶层声明入 core 直属。
  engine = project.objects.find { |o| o.isa == 'PBXGroup' && o.name == 'ChuanqiCutEngine' }
  added = 0
  if engine
    # 清掉旧形态的 core 组（镜像树版/独立浏览组），全量重建
    old_core = engine.children.find { |c| c.isa == 'PBXGroup' && c.display_name == 'core' }
    old_core&.remove_from_project

    ensure_group = lambda do |parent, name|
      parent.children.find { |c| c.isa == 'PBXGroup' && c.display_name == name } ||
        parent.new_group(name)
    end
    add_file = lambda do |group, abs|
      exists = group.children.any? do |c|
        c.isa == 'PBXFileReference' && c.real_path.exist? && c.real_path.to_s == abs
      end
      return if exists
      ref = group.new_file(abs)
      ref.source_tree = 'SOURCE_ROOT'
      ref.path = Pathname.new(abs).relative_path_from(project.path.dirname).to_s
      added += 1
    end
    add_tree = lambda do |group, dir, exts|
      Pathname.new(dir).children.sort.each do |child|
        if child.directory?
          add_tree.call(ensure_group.call(group, child.basename.to_s), child.to_s, exts)
        elsif exts.include?(child.extname)
          add_file.call(group, child.to_s)
        end
      end
    end

    src_root  = File.join(repo_root, 'engine/core/src')
    inc_root  = File.join(repo_root, 'engine/core/include/cq')
    core = ensure_group.call(engine, 'core')

    modules = (Pathname.new(src_root).children.select(&:directory?).map { |c| c.basename.to_s } +
               Pathname.new(inc_root).children.select(&:directory?).map { |c| c.basename.to_s }).uniq.sort
    modules.each do |mod|
      g = ensure_group.call(core, mod)
      inc_dir = File.join(inc_root, mod)
      src_dir = File.join(src_root, mod)
      add_tree.call(g, inc_dir, ['.h'])  if File.directory?(inc_dir)
      add_tree.call(g, src_dir, ['.cpp']) if File.directory?(src_dir)
    end
    # 顶层散件（cq_sdk.cpp 等）与 include/cq 直属头 → core 直属
    add_tree.call(core, src_root, ['.cpp'])
    add_tree.call(core, inc_root, ['.h'])
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
