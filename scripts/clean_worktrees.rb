#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "optparse"
require "fileutils"
require "time"
require_relative "native_job"

# Frees disk held by linked agent worktrees. Removes worktrees whose PR is
# merged or closed (and that carry no tracked changes); for the rest, deletes
# only regenerable build directories once the worktree has been idle for 24 h.
# An unknown PR state (gh offline, no PR, detached HEAD) never removes anything.
#
# --auto is the unattended mode used by build-storage reclaim: it never removes
# a worktree or asks GitHub, skips worktrees with uncommitted files and, after
# 72 h idle, also deletes Rust debug profiles. Release libraries and the
# verified prebuilt runtimes under target/ are kept.
module CleanWorktrees
  GIB = 1024.0**3
  IDLE_SECONDS = 24 * 3600
  AUTO_IDLE_SECONDS = 72 * 3600
  RUST_DEBUG_GLOBS = %w[target/debug target/*/debug].freeze
  RUST_KEPT = %w[native-prebuilt onnxruntime-macos-prebuilt espeak-data].freeze
  BUILD_DIRS = %w[ios/EpubToMp3/.build tools/DeviceWorkflow/.build ios/EpubToMp3/tools/DeviceWorkflow/.build].freeze
  BUSY_PROGRAMS = %w[xcodebuild cargo rustc swift-build swift-frontend swift-package swift-test device-workflow DeviceWorkflow].freeze
  COMPILER_PHASES = %w[build heavy].freeze

  class Refused < RuntimeError; end

  Worktree = Struct.new(:path, :branch, :locked, keyword_init: true)

  def self.git(*args, chdir:)
    out, status = Open3.capture2e("git", *args, chdir: chdir)
    [out, status.success?]
  end

  # Linked worktrees only: the first porcelain record is the main checkout.
  def self.list(root)
    out, ok = git("worktree", "list", "--porcelain", chdir: root)
    raise "git worktree list failed: #{out}" unless ok

    out.split(/\n\n+/).drop(1).filter_map do |block|
      fields = block.lines.map(&:chomp)
      path = fields.find { |l| l.start_with?("worktree ") }&.delete_prefix("worktree ")
      next unless path

      branch = fields.find { |l| l.start_with?("branch ") }&.delete_prefix("branch refs/heads/")
      Worktree.new(path: path, branch: branch, locked: fields.any? { |l| l.start_with?("locked") })
    end
  end

  # :open / :done / :unknown. Only :done permits removal.
  def self.gh_pr_state(root, branch)
    out, status = Open3.capture2("gh", "pr", "list", "--state", "all", "--head", branch, "--json", "state", chdir: root)
    return :unknown unless status.success?

    states = JSON.parse(out).map { |pr| pr["state"] }
    return :unknown if states.empty?

    states.all? { |s| %w[MERGED CLOSED].include?(s) } ? :done : :open
  rescue StandardError
    :unknown
  end

  # [{ args:, cwd: }] for every process whose program looks like a build tool.
  def self.running_processes
    out, = Open3.capture2("ps", "-axo", "pid=,args=")
    found = out.lines.filter_map do |line|
      pid, args = line.strip.split(/\s+/, 2)
      next unless pid&.match?(/\A\d+\z/) && args
      next unless args.split.any? { |part| BUSY_PROGRAMS.include?(File.basename(part)) }

      [pid, args]
    end
    cwds = {}
    unless found.empty?
      lsof, = Open3.capture2("lsof", "-a", "-d", "cwd", "-Fpn", "-p", found.map(&:first).join(","))
      pid = nil
      lsof.each_line do |l|
        pid = l[1..].strip if l.start_with?("p")
        cwds[pid] = l[1..].strip if l.start_with?("n")
      end
    end
    found.map { |pid, args| { args: args, cwd: cwds[pid] } }
  rescue SystemCallError
    []
  end

  def self.inside?(path, root)
    path = path.to_s
    path == root || path.start_with?(root + "/")
  end

  def self.busy?(wt, processes)
    processes.any? do |proc_|
      inside?(proc_[:cwd], wt.path) || proc_[:args].to_s.split.any? { |part| inside?(part, wt.path) }
    end
  end

  # Newest mtime among tracked files and the HEAD reflog.
  def self.last_activity(wt)
    out, = git("ls-files", "-z", chdir: wt.path)
    times = out.split("\0").filter_map { |f| File.lstat(File.join(wt.path, f)).mtime rescue nil }
    log, ok = git("rev-parse", "--git-path", "logs/HEAD", chdir: wt.path)
    if ok
      reflog = File.expand_path(log.strip, wt.path)
      times << File.mtime(reflog) if File.exist?(reflog)
    end
    times.max
  end

  # [tracked_changes, other_untracked, build_untracked]
  def self.status(wt)
    out, ok = git("status", "--porcelain", chdir: wt.path)
    return nil unless ok

    tracked = []
    other = []
    out.lines.map(&:chomp).each do |line|
      next tracked << line unless line.start_with?("?? ")

      name = line[3..].delete_suffix("/")
      BUILD_DIRS.any? { |d| ("/" + name + "/").include?("/" + d + "/") } ? nil : other << line
    end
    [tracked, other]
  end

  def self.size(path)
    out, = Open3.capture2("du", "-sk", path)
    out.to_i * 1024
  rescue SystemCallError
    0
  end

  def self.build_dirs(wt, rust_debug: false)
    dirs = BUILD_DIRS.map { |d| File.join(wt.path, d) }
    if rust_debug
      dirs += RUST_DEBUG_GLOBS.flat_map { |pattern| Dir.glob(pattern, base: wt.path) }
                              .reject { |relative| RUST_KEPT.include?(relative.split("/")[1]) && relative != "target/debug" }
                              .map { |relative| File.join(wt.path, relative) }
    end
    dirs.uniq.select { |d| File.directory?(d) && !File.symlink?(d) && !File.symlink?(File.dirname(d)) }
  end

  def self.auto_plan(wt, base, now)
    tracked, other = status(wt)
    return base.merge(action: :skip, reason: "git status failed") unless tracked
    return base.merge(action: :skip, reason: "uncommitted files") unless tracked.empty? && other.empty?

    idle = last_activity(wt)
    dirs = build_dirs(wt, rust_debug: true)
    unless idle && now - idle > AUTO_IDLE_SECONDS && !dirs.empty?
      return base.merge(action: :skip, reason: "active within 72 h or no build output")
    end

    base.merge(action: :clean_build, reason: "idle #{((now - idle) / 3600).floor} h", dirs: dirs,
               bytes: dirs.sum { |d| size(d) })
  end

  # Returns an array of action hashes: { worktree:, action:, reason:, bytes: }.
  def self.plan(root, pr_state:, processes:, holder: nil, now: Time.now, auto: false)
    list(root).map do |wt|
      base = { worktree: wt.path, branch: wt.branch }
      next base.merge(action: :skip, reason: "locked worktree") if wt.locked
      next base.merge(action: :skip, reason: "named by the lease holder record") if holder && holder.to_s != "" && File.basename(wt.path) == holder
      next base.merge(action: :skip, reason: "build process running inside") if busy?(wt, processes)
      next base.merge(action: :skip, reason: "directory missing (run git worktree prune)") unless File.directory?(wt.path)
      next auto_plan(wt, base, now) if auto

      tracked, other = status(wt)
      next base.merge(action: :skip, reason: "git status failed") unless tracked
      state = wt.branch ? pr_state.call(root, wt.branch) : :unknown
      if state == :done
        next base.merge(action: :report, reason: "PR closed but #{tracked.size} tracked change(s) remain") unless tracked.empty?
        next base.merge(action: :report, reason: "PR closed but untracked files remain: #{other.first(3).join(', ')}") unless other.empty?

        next base.merge(action: :remove, reason: "PR merged or closed", bytes: size(wt.path))
      end
      idle = last_activity(wt)
      dirs = build_dirs(wt)
      if idle && now - idle > IDLE_SECONDS && !dirs.empty?
        next base.merge(action: :clean_build, reason: "idle #{((now - idle) / 3600).floor} h, PR #{state}", dirs: dirs,
                        bytes: dirs.sum { |d| size(d) })
      end
      base.merge(action: :skip, reason: "PR #{state}, active or no build dirs#{tracked.empty? ? '' : ', tracked changes'}")
    end
  end

  def self.execute(root, item)
    case item[:action]
    when :remove
      _, ok = git("worktree", "remove", item[:worktree], chdir: root)
      # Only ignored/untracked build dirs remain (checked by plan): forcing is safe.
      _, ok = git("worktree", "remove", "--force", item[:worktree], chdir: root) unless ok
      ok
    when :clean_build
      item[:dirs].each { |d| FileUtils.rm_rf(d) }
      true
    end
  end

  def self.holder_name(lock)
    record = NativeJob.holder(lock)
    record && record["worktree"]
  end

  # Refuses while any job holds the native lease, like clean:build. The lease is
  # kept for the whole cleanup so no job starts in the middle.
  def self.run(root:, lock: NativeJob::LOCK_PATH, dry_run: false, pr_state: method(:gh_pr_state),
               processes: nil, out: $stdout, auto: false)
    File.open(lock, File::RDWR | File::CREAT, 0o600) do |lease|
      unless lease.flock(File::LOCK_EX | File::LOCK_NB)
        record = NativeJob.holder(lock)
        raise Refused, "A native/heavy job is active#{record ? " (#{record['phase']} in #{record['worktree']})" : ''}; cleanup refused"
      end
      procs = processes ? processes.call : running_processes
      if procs.any? { |p| p[:args].to_s.split.any? { |part| %w[xcodebuild cargo rustc swift-frontend].include?(File.basename(part)) } }
        raise Refused, "A compiler is active; cleanup refused"
      end
      items = plan(root, pr_state: pr_state, processes: procs, holder: holder_name(lock), auto: auto)
      freed = 0
      items.each do |item|
        verb = { remove: "remove worktree", clean_build: "delete build dirs", report: "REPORT", skip: "skip" }.fetch(item[:action])
        if %i[remove clean_build].include?(item[:action]) && !dry_run
          if execute(root, item)
            freed += item[:bytes].to_i
            out.puts "removed #{item[:worktree]} (#{item[:action]}, #{format('%.2f', item[:bytes].to_i / GIB)} GiB)"
          else
            out.puts "FAILED #{item[:worktree]}"
          end
        else
          size = item[:bytes] ? " (#{format('%.2f', item[:bytes] / GIB)} GiB)" : ""
          out.puts "#{dry_run ? 'plan: ' : ''}#{verb}: #{item[:worktree]}#{size} - #{item[:reason]}"
        end
      end
      out.puts(dry_run ? "dry run: nothing removed" : "freed #{format('%.2f', freed / GIB)} GiB")
    end
    0
  end

  def self.main(arguments, **options)
    dry = false
    auto = false
    OptionParser.new do |o|
      o.on("--dry-run") { dry = true }
      o.on("--auto") { auto = true }
    end.parse!(arguments)
    root = options.delete(:root) || File.expand_path("..", __dir__)
    # Resolve the main checkout so running from a linked worktree still works.
    common, ok = git("rev-parse", "--path-format=absolute", "--git-common-dir", chdir: root)
    root = File.dirname(common.strip) if ok && File.basename(common.strip) == ".git"
    run(root: root, dry_run: dry, auto: auto, **options)
  rescue Refused => error
    warn "clean_worktrees: #{error.message}"
    75
  rescue StandardError => error
    warn "clean_worktrees: #{error.message}"
    1
  end
end

exit CleanWorktrees.main(ARGV) if $PROGRAM_NAME == __FILE__
