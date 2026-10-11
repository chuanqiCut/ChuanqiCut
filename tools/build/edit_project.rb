#!/usr/bin/env ruby
# edit_project.rb — 壳工程结构化编辑通道（ADR-0037 配套，2026-10-11）
#
# 背景：壳工程冻结入库后（ADR-0037），ChuanqiCut.xcodeproj 是手工源文件。
# **agent / 脚本禁止裸编 project.pbxproj 文本** —— 结构化改动一律走本脚本
#（基于 xcodeproj gem 1.28+，与 pod install 用同一库写工程，round-trip 安全）。
#
# 前提（ADR-0037 台阶 2）：app 目标源码已升级为 synchronized groups（buildable
# folders）——**app 内加/删文件 = 纯文件系统操作，不需要动工程**；本脚本的
# add-file 只对仍用经典引用的组有意义。
#
# 用法：
#   edit_project.rb show           <project> [target_name]
#   edit_project.rb set-setting    <project> <target_name> <key> <value> [base|Debug|Release]
#   edit_project.rb add-script-phase <project> <target_name> <name> <script_file> [--pre]
#   edit_project.rb add-file       <project> <target_name> <path> [sources|resources]
#   edit_project.rb add-remote-dependency <project> <target_name> <remote_project> <remote_target_name>
#
# add-remote-dependency：把本工程 target 依赖到另一个工程（Pods.xcodeproj）里的
# target（如聚合 target Pods-<App>）。补齐 containerPortal + PBXContainerItemProxy +
# PBXTargetDependency 三件（CocoaPods 1.17 把聚合 target 放进 Pods 工程后，用户工程
# 只写 xcconfig 不写依赖曾致"Pods 永不构建"的假绿——2026-10-11 实录）。幂等。
#
# 注意：改完工程后直接 git commit（工程是源文件）；不需要任何重新生成步骤。

require 'xcodeproj'

def load_target(project_path, target_name)
  proj = Xcodeproj::Project.open(project_path)
  target = proj.targets.find { |t| t.name == target_name }
  abort "ERROR: target '#{target_name}' not found in #{project_path}" unless target
  [proj, target]
end

def sync_note(target)
  sync = target.respond_to?(:file_system_synchronized_groups) ? target.file_system_synchronized_groups : []
  unless sync.empty?
    puts "NOTE: target '#{target.name}' 使用 synchronized groups（#{sync.map(&:path).join(', ')}）——" \
         '目标目录内加/删文件直接放文件即可，无需本操作。'
  end
end

command = ARGV.shift or abort "usage: edit_project.rb <show|set-setting|add-script-phase|add-file> ..."
project_path = ARGV.shift or abort 'ERROR: 缺 <project> 路径（如 apps/apple/ios/ChuanqiCut.xcodeproj）'

case command
when 'show'
  proj, target = load_target(project_path, ARGV.shift)
  sync_note(target)
  puts "target: #{target.name} (#{target.product_type})"
  puts 'build settings (base):'
  target.build_configurations.each do |cfg|
    puts "  [#{cfg.name}]"
    cfg.build_settings.sort.each { |k, v| puts "    #{k} = #{v}" }
  end
  puts 'build phases:'
  target.build_phases.each_with_index do |ph, i|
    extra = ph.respond_to?(:shell_script) ? " :: #{ph.shell_script[0, 60]}..." : ''
    puts "  [#{i}] #{ph.class.name.split('::').last} #{ph.display_name}#{extra}"
  end
  if target.respond_to?(:file_system_synchronized_groups)
    puts "synchronized groups: #{target.file_system_synchronized_groups.map(&:path).inspect}"
  end

when 'set-setting'
  proj, target = load_target(project_path, ARGV.shift)
  key = ARGV.shift or abort 'ERROR: 缺 <key>'
  value = ARGV.shift or abort 'ERROR: 缺 <value>'
  config_name = ARGV.shift || 'base'
  if config_name == 'base'
    target.build_settings[key] = value
  else
    cfg = target.build_configurations.find { |c| c.name == config_name }
    abort "ERROR: configuration '#{config_name}' 不存在" unless cfg
    cfg.build_settings[key] = value
  end
  proj.save
  puts "OK: #{target.name}.#{config_name}.#{key} = #{value}"

when 'add-script-phase'
  proj, target = load_target(project_path, ARGV.shift)
  name = ARGV.shift or abort 'ERROR: 缺 <name>'
  script_file = ARGV.shift or abort 'ERROR: 缺 <script_file>'
  pre = ARGV.include?('--pre')
  script = File.read(script_file)
  phase = pre ? target.new_shell_script_build_phase(name) : target.new_shell_script_build_phase(name)
  # xcodeproj 无 pre/post 之分——插入位置由调用方用 Xcode 调整或改用本行下方注释：
  #   target.build_phases.move(phase, 0)  # 移到最前
  phase.shell_script = script
  phase.run_only_for_deployment_postprocessing = '0'
  proj.save
  puts "OK: 已加脚本阶段 '#{name}'（默认追加到末尾；签名类阶段必须在最后——ADR-0021 口径）"

when 'add-file'
  proj, target = load_target(project_path, ARGV.shift)
  sync_note(target)
  path = ARGV.shift or abort 'ERROR: 缺 <path>'
  phase_kind = ARGV.shift || 'sources'
  file_ref = proj.main_group.find_file_by_path(path) ||
             proj.main_group.new_file(path)
  phase = case phase_kind
          when 'resources' then target.resources_build_phase
          else target.source_build_phase
          end
  phase.add_file_reference(file_ref)
  proj.save
  puts "OK: #{path} → #{target.name}.#{phase_kind}"

when 'add-remote-dependency'
  proj, target = load_target(project_path, ARGV.shift)
  remote_project_path = ARGV.shift or abort 'ERROR: 缺 <remote_project>（如 Pods/Pods.xcodeproj）'
  remote_target_name = ARGV.shift or abort 'ERROR: 缺 <remote_target_name>'
  remote_proj = Xcodeproj::Project.open(remote_project_path)
  remote_target = remote_proj.targets.find { |t| t.name == remote_target_name }
  abort "ERROR: remote target '#{remote_target_name}' not found in #{remote_project_path}" unless remote_target

  # 幂等：已有指向同一 remote uuid 的依赖就不重复加
  already = target.dependencies.any? do |d|
    d.target_proxy && d.target_proxy.remote_global_id_string == remote_target.uuid
  end
  if already
    puts "SKIP: #{target.name} 已依赖 #{remote_target_name}（#{remote_project_path}）"
  else
    portal = proj.files.find { |f| f.path == remote_project_path } ||
             proj.new_file(remote_project_path)
    portal.last_known_file_type = 'wrapper.pb-project'
    proxy = proj.new(Xcodeproj::Project::Object::PBXContainerItemProxy)
    proxy.container_portal = portal.uuid
    proxy.proxy_type = '1'
    proxy.remote_global_id_string = remote_target.uuid
    proxy.remote_info = remote_target.name
    dep = proj.new(Xcodeproj::Project::Object::PBXTargetDependency)
    dep.target_proxy = proxy
    target.dependencies << dep
    proj.save
    puts "OK: #{target.name} → #{remote_target_name}（#{remote_project_path}, uuid #{remote_target.uuid}）"
  end

else
  abort "ERROR: 未知子命令 '#{command}'"
end
