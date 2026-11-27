# frozen_string_literal: true

require "json"
require "open3"
require "fileutils"
require "find"

# Run as a script by a relative path, this file is required again by absolute
# path through native_job; the second load would redefine every constant.
return if defined?(MacBuildBudget::ROOT)

# Build storage only: books, models, app data, tools and evidence are excluded.
# Free space is advisory: a low reading is reported, never a reason to refuse or
# stop a build (Pietro removed the storage floors on 2026-11-22). Only explicit
# cache cleanup keeps its own safety checks, because deleting a cache under a
# running build corrupts it.
#
# reclaim is the automatic upkeep: native_job runs reclaim-if-low after a host
# job and the owner's hourly disk check may run reclaim. It removes superseded
# DerivedData, diagnostic bundles older than a week and the build output of
# worktrees idle for 72 h. Locked worktrees (`git worktree lock`) and worktrees
# with uncommitted files are never touched.
module MacBuildBudget
  ROOT = File.expand_path("..", __dir__)
  POLICY = File.join(ROOT, "config/mac-build-budget.json")
  LOCK = "/tmp/epub2mp3.heavy-job.lock"
  GIB = 1024**3
  # Diagnostic bundles only: books, backups, receipts and text logs stay.
  DIAGNOSTIC_EXTENSIONS = %w[.xcresult .logarchive .app .ipa .dSYM].freeze
  DIAGNOSTIC_DAYS = 7
  # A directory holding this file is retained whole, with everything below it.
  RETAIN_MARKER = ".retain"
  BOOK_GLOB = "**/*.{epub,EPUB,pdf,PDF}"
  DIAGNOSTICS_ENV = "EPUB_DIAGNOSTICS_DIR"

  def self.capture(*argv)
    output, error, status = Open3.capture3(*argv)
    raise "#{argv.first} inspection failed: #{error.strip}" unless status.success?
    output
  end

  def self.policy
    value = JSON.parse(File.read(POLICY))
    raise "Invalid build budget version" unless value["version"] == 1
    raise "Invalid build budget warn_free_gib" unless value["warn_free_gib"].is_a?(Integer) && value["warn_free_gib"].positive?
    value
  end

  # The main checkout first, then linked worktrees, with their lock state.
  def self.worktree_records
    capture("git", "-C", ROOT, "worktree", "list", "--porcelain").split(/\n\n+/).filter_map do |block|
      fields = block.lines.map(&:chomp)
      path = fields.find { |field| field.start_with?("worktree ") }&.delete_prefix("worktree ")
      next unless path && File.directory?(path)

      { path: File.realpath(path), locked: fields.any? { |field| field == "locked" || field.start_with?("locked ") } }
    end.uniq { |record| record[:path] }
  end

  def self.worktrees
    worktree_records.map { |record| record[:path] }
  end

  def self.unlocked_worktrees
    worktree_records.reject { |record| record[:locked] }.map { |record| record[:path] }
  end

  def self.clean_checkout?(path)
    output, status = Open3.capture2("git", "-C", path, "status", "--porcelain")
    status.success? && output.empty?
  end

  # Automatic reclaim leaves alone what a person may still be working on.
  def self.reclaimable_worktrees
    unlocked_worktrees.select { |path| clean_checkout?(path) }
  end

  def self.xcode_caches
    parent = File.expand_path("~/Library/Developer/Xcode/DerivedData")
    Dir.glob(File.join(parent, "EpubToMp3-*")).select { |path| File.lstat(path).directory? }
  end

  def self.legacy_caches(roots = unlocked_worktrees)
    expected = roots.map { |root| File.join(root, "ios/EpubToMp3/EpubToMp3.xcodeproj") }
    xcode_caches.select do |path|
      info = File.join(path, "info.plist")
      next false unless File.file?(info)
      workspace = capture("plutil", "-extract", "WorkspacePath", "raw", "-o", "-", info).strip
      expected.include?(File.expand_path(workspace))
    end
  end

  def self.build_host?(host = RUBY_PLATFORM, arch_release: "/etc/arch-release")
    host.include?("darwin") || (host.include?("linux") && File.file?(arch_release))
  end

  # A compiler can create its output tree after admission. Its nearest existing
  # directory already identifies the receiving volume, including symlink targets.
  def self.metrics(destination = ROOT)
    raise "Empty build destination" if destination.empty?
    path = File.expand_path(destination)
    ancestor = path
    loop do
      File.lstat(ancestor)
      break
    rescue Errno::ENOENT
      ancestor = File.dirname(ancestor)
    end
    ancestor = File.realpath(ancestor)
    raise "Build destination is not a directory: #{ancestor}" unless File.directory?(ancestor)
    row = capture("df", "-Pk", ancestor).lines.last.to_s
    available = row.match(/\A.+?\s+\d+\s+\d+\s+(-?\d+)\s+\d+%\s+/)
    raise "Missing available space for #{ancestor}" unless available
    { destination: path, measured_path: ancestor, free_bytes: available[1].to_i * 1024 }
  end

  def self.evaluate(limits, free_bytes:, destination:, **)
    floor = limits.fetch("warn_free_gib")
    "Free disk below #{floor} GiB at #{destination}." if free_bytes < floor * GIB
  end

  # The first low-space note, or nil. Unreadable storage is a note too.
  def self.check(*destinations, host: RUBY_PLATFORM)
    return unless build_host?(host)
    limits = policy
    (destinations.empty? ? [ROOT] : destinations).each do |destination|
      error = evaluate(limits, **metrics(destination))
      return error if error
    end
    nil
  rescue StandardError => error
    "Build storage inspection failed (#{error.class}: #{error.message})."
  end

  # Reports the note without ever blocking the build.
  def self.advise(*destinations, host: RUBY_PLATFORM)
    note = check(*destinations, host: host)
    warn "native_job: advisory, not a refusal: #{note}" if note
    note
  end

  # The shared diagnostics directory beside the main checkout and the
  # .reports directory of each given worktree (by default every unlocked one).
  def self.diagnostic_roots(checkouts = unlocked_worktrees)
    main = worktrees.first || ROOT
    shared = ENV[DIAGNOSTICS_ENV] || File.join(File.dirname(main), "#{File.basename(main)}-logs")
    roots = [shared, *checkouts.map { |path| File.join(path, ".reports") }]
    roots.uniq.select { |path| File.directory?(path) && !File.symlink?(path) }
  end

  def self.retained_directory?(path, name)
    name.start_with?("library-backup-", "worktree-backup-") || name.end_with?(".bundle") || File.exist?(File.join(path, RETAIN_MARKER))
  end

  # Diagnostic bundles older than the retention window. Never follows links,
  # never descends into retained, backup or resource-bundle directories, and
  # keeps any bundle that carries a book.
  def self.expired_diagnostics(roots, now: Time.now, days: DIAGNOSTIC_DAYS)
    cutoff = now - days * 86_400
    roots.flat_map do |root|
      next [] if File.exist?(File.join(root, RETAIN_MARKER))

      found = []
      Find.find(root) do |path|
        next if path == root

        stat = File.lstat(path)
        Find.prune if stat.symlink?
        name = File.basename(path)
        Find.prune if stat.directory? && retained_directory?(path, name)
        next unless DIAGNOSTIC_EXTENSIONS.include?(File.extname(name))

        found << path if stat.mtime < cutoff && (stat.file? || Dir.glob(BOOK_GLOB, base: path).empty?)
        Find.prune if stat.directory?
      end
      found
    end
  end

  def self.size_bytes(path)
    output, status = Open3.capture2("du", "-sk", path)
    status.success? ? output.to_i * 1024 : 0
  end

  def self.remove(path, label, dry_run:, out:)
    if dry_run
      out.puts "plan: remove #{label}: #{path}"
      return
    end
    # Recheck identity immediately before removal; never follow links.
    stat = File.lstat(path)
    raise "Path changed; cleanup refused: #{path}" if stat.symlink? || File.realpath(path) != path
    out.puts "Removing #{label}: #{path}"
    FileUtils.remove_entry_secure(path)
  end

  def self.prune(lock: LOCK, dry_run: false, diagnostics: false, roots: nil, out: $stdout)
    File.open(lock, "a+") do |lease|
      raise "A native/heavy job is active; cleanup refused" unless lease.flock(File::LOCK_EX | File::LOCK_NB)
      processes = capture("ps", "-axo", "comm=").lines.map(&:strip)
      raise "A compiler is active; cleanup refused" if processes.any? { |path| %w[xcodebuild cargo rustc swift-frontend].include?(File.basename(path)) }
      (roots ? legacy_caches(roots) : legacy_caches).each do |path|
        raise "The old cache contains a running app; cleanup refused" if processes.any? { |executable| executable.start_with?(path + "/") }
        raise "Cache path changed; cleanup refused" unless File.lstat(path).directory?
        remove(path, "superseded Xcode cache", dry_run: dry_run, out: out)
      end
      next unless diagnostics

      expired_diagnostics(roots ? diagnostic_roots(roots) : diagnostic_roots).each do |path|
        next if processes.any? { |executable| executable.start_with?(path + "/") }

        remove(path, "expired diagnostic", dry_run: dry_run, out: out)
      end
    end
  end

  def self.reclaim_worktree_builds(lock: LOCK, dry_run: false, out: $stdout)
    require_relative "clean_worktrees"
    main = worktrees.first || ROOT
    CleanWorktrees.run(root: main, lock: lock, dry_run: dry_run, auto: true, out: out)
  end

  # Automatic upkeep: superseded DerivedData of clean, unlocked worktrees,
  # expired diagnostics, then the build output of idle worktrees. Each step
  # takes the lease on its own and refuses while a job holds it.
  def self.reclaim(lock: LOCK, dry_run: false, out: $stdout)
    prune(lock: lock, dry_run: dry_run, diagnostics: true, roots: reclaimable_worktrees, out: out)
    reclaim_worktree_builds(lock: lock, dry_run: dry_run, out: out)
  end

  def self.main(arguments)
    command, *destinations = arguments
    case command
    when "check"
      advise(*destinations)
    when "status"
      raise "Build storage status requires macOS or Arch Linux" unless build_host?
      limits = policy
      destinations = [ROOT] if destinations.empty?
      snapshots = destinations.map { |path| metrics(path) }
      details = snapshots.one? ? snapshots.first : { destinations: snapshots }
      low = snapshots.lazy.map { |snapshot| evaluate(limits, **snapshot) }.find(&:itself)
      diagnostics = begin
        diagnostic_roots.map { |path| { path: path, bytes: size_bytes(path) } }
      rescue StandardError => error
        "unavailable (#{error.class})"
      end
      puts JSON.pretty_generate({ policy: limits, **details, low_space_note: low, diagnostic_storage: diagnostics })
    when "prune", "prune-if-low", "reclaim", "reclaim-if-low"
      raise "Cleanup requires macOS" unless RUBY_PLATFORM.include?("darwin")
      dry_run = !destinations.delete("--dry-run").nil?
      raise "Cleanup does not accept a destination" unless destinations.empty?
      if command.end_with?("-if-low") && metrics.fetch(:free_bytes) >= policy.fetch("warn_free_gib") * GIB
        return 0
      end

      command.start_with?("reclaim") ? reclaim(dry_run: dry_run) : prune(dry_run: dry_run)
    else raise "Usage: mac_build_budget.rb check|status [DIRECTORY ...] | prune|prune-if-low|reclaim|reclaim-if-low [--dry-run]"
    end
    0
  rescue StandardError => error
    warn "Build storage: #{error.message}"
    75
  end
end

exit MacBuildBudget.main(ARGV) if $PROGRAM_NAME == __FILE__
