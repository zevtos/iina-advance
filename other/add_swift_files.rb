#!/usr/bin/env ruby
#
# add_swift_files.rb — add Swift source files to the iina Xcode target.
#
# IINA's project.pbxproj is a v54 (Xcode 13) project without synchronized
# folder groups, so every new .swift file must be wired up in the project
# tree explicitly. This helper does that idempotently: re-running it with
# files already in the project is a no-op.
#
# Usage:
#   ruby other/add_swift_files.rb iina/HDR_Controller.swift iina/PerfManager.swift
#
# Requires: gem install --user-install xcodeproj  (already in dev setup)

require "rubygems"

# Make user-installed gems discoverable on system Ruby.
ENV["GEM_PATH"] = "#{Gem.user_dir}:#{ENV.fetch("GEM_PATH", "")}"
Gem.refresh

require "xcodeproj"

PROJECT = File.expand_path("../iina.xcodeproj", __dir__)
TARGET_NAME = "iina"
PARENT_GROUP_NAME = "iina"

def find_or_add_to_target(project, target, parent_group, abs_path)
  rel_path = abs_path.sub("#{File.dirname(File.dirname(parent_group.real_path))}/", "")
  basename = File.basename(rel_path)

  existing = parent_group.files.find { |f| f.path == basename || f.real_path.to_s == abs_path }
  if existing
    if target.source_build_phase.files_references.include?(existing)
      puts "skip: #{basename} (already in target)"
      return :unchanged
    else
      target.source_build_phase.add_file_reference(existing)
      puts "wire: #{basename} (file ref existed but not in build phase)"
      return :wired
    end
  end

  ref = parent_group.new_reference(basename)
  ref.last_known_file_type = "sourcecode.swift"
  target.source_build_phase.add_file_reference(ref)
  puts "add:  #{basename}"
  :added
end

def main(argv)
  abort "Usage: #{$PROGRAM_NAME} file.swift [more.swift ...]" if argv.empty?

  project = Xcodeproj::Project.open(PROJECT)
  target = project.targets.find { |t| t.name == TARGET_NAME }
  abort "Target #{TARGET_NAME.inspect} not found" unless target

  iina_group = project.main_group[PARENT_GROUP_NAME]
  abort "Group #{PARENT_GROUP_NAME.inspect} not found" unless iina_group

  any_changes = false
  argv.each do |path|
    abs = File.expand_path(path)
    abort "Not found: #{abs}" unless File.exist?(abs)
    abort "Expected a .swift under iina/, got #{path}" unless abs.start_with?("#{iina_group.real_path}/")

    result = find_or_add_to_target(project, target, iina_group, abs)
    any_changes ||= result != :unchanged
  end

  if any_changes
    project.save
    puts "project saved"
  else
    puts "no changes"
  end
end

main(ARGV)
