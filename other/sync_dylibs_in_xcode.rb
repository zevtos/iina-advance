#!/usr/bin/env ruby
#
# sync_dylibs_in_xcode.rb — make iina.xcodeproj's link phase match the dylibs
# actually present in deps/lib/.
#
# The project file was set up against the old upstream IINA dylib bundle
# (downloaded from iina.io). The custom libmpv build (`other/build_mpv.sh`)
# produces a different set with newer versions, so most of the original
# references no longer resolve. This script:
#
#   1. removes file references / build phase entries that point to dylibs
#      *not* in deps/lib/,
#   2. adds new file references and Frameworks build phase entries for any
#      dylib that *is* in deps/lib/ but isn't already referenced.
#
# Idempotent: safe to re-run after each `build_mpv.sh` rebuild.
#
# Usage:  ruby other/sync_dylibs_in_xcode.rb

require "rubygems"
require "set"
ENV["GEM_PATH"] = "#{Gem.user_dir}:#{ENV.fetch("GEM_PATH", "")}"
Gem.refresh
require "xcodeproj"

PROJECT_PATH = File.expand_path("../iina.xcodeproj", __dir__)
DEPS_LIB     = File.expand_path("../deps/lib", __dir__)
TARGET_NAME  = "iina"

def main
  abort "deps/lib/ not found at #{DEPS_LIB} — run other/build_mpv.sh first" \
    unless Dir.exist?(DEPS_LIB)

  on_disk = Dir.children(DEPS_LIB).select { |f| f.end_with?(".dylib") }.to_set
  puts "deps/lib has #{on_disk.size} dylibs"

  project = Xcodeproj::Project.open(PROJECT_PATH)
  target = project.targets.find { |t| t.name == TARGET_NAME }
  abort "target #{TARGET_NAME.inspect} not found" unless target

  frameworks_phase = target.frameworks_build_phase

  # 1. Remove references to dylibs no longer on disk.
  removed = 0
  refs_to_remove = []
  project.files.each do |ref|
    next unless ref.path&.end_with?(".dylib")
    next unless ref.path.start_with?("deps/") || File.basename(ref.path).start_with?("lib")
    basename = File.basename(ref.path)
    next if on_disk.include?(basename)
    refs_to_remove << ref
  end

  refs_to_remove.each do |ref|
    # Drop from any build phase that mentions it.
    project.targets.each do |t|
      t.build_phases.each do |phase|
        phase.files.dup.each do |bf|
          if bf.file_ref == ref
            phase.remove_build_file(bf)
          end
        end
      end
    end
    ref.remove_from_project
    removed += 1
    puts "remove: #{ref.path}"
  end

  # 2. Add references for dylibs on disk but not already in project.
  existing_basenames = project.files
                              .select { |f| f.path&.end_with?(".dylib") }
                              .map { |f| File.basename(f.path) }
                              .to_set

  # Find or create a "Frameworks" group under the project root for new refs.
  frameworks_group = project.main_group["Frameworks"] \
                  || project.main_group.new_group("Frameworks")

  added = 0
  missing = on_disk.reject { |n| existing_basenames.include?(n) }
  missing.sort.each do |basename|
    rel_path = "deps/lib/#{basename}"
    ref = frameworks_group.new_reference(rel_path)
    ref.last_known_file_type = "compiled.mach-o.dylib"
    frameworks_phase.add_file_reference(ref)
    added += 1
    puts "add:    deps/lib/#{basename}"
  end

  if removed > 0 || added > 0
    project.save
    puts "saved: #{removed} removed, #{added} added"
  else
    puts "no changes"
  end
end

main
