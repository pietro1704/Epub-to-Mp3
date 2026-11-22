# frozen_string_literal: true

require "json"
require "open3"
require "fileutils"

# Build storage only: books, models, app data, tools and evidence are excluded.
# Free space is advisory: a low reading is reported, never a reason to refuse or
# stop a build (Pietro removed the storage floors on 2026-11-22). Only explicit
# cache cleanup keeps its own safety checks, because deleting a cache under a
# running build corrupts it.
module MacBuildBudget
  ROOT = File.expand_path("..", __dir__)
  POLICY = File.join(ROOT, "config/mac-build-budget.json")
  LOCK = "/tmp/epub2mp3.heavy-job.lock"
  GIB = 1024**3

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

  def self.worktrees
    capture("git", "-C", ROOT, "worktree", "list", "--porcelain").lines.filter_map do |line|
      path = line.delete_prefix("worktree ").strip if line.start_with?("worktree ")
      File.realpath(path) if path && File.directory?(path)
    end.uniq
  end

  def self.xcode_caches
    parent = File.expand_path("~/Library/Developer/Xcode/DerivedData")
    Dir.glob(File.join(parent, "EpubToMp3-*")).select { |path| File.lstat(path).directory? }
  end

  def self.legacy_caches
    expected = worktrees.map { |root| File.join(root, "ios/EpubToMp3/EpubToMp3.xcodeproj") }
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

  def self.prune(lock: LOCK)
    File.open(lock, "a+") do |lease|
      raise "A native/heavy job is active; cleanup refused" unless lease.flock(File::LOCK_EX | File::LOCK_NB)
      processes = capture("ps", "-axo", "comm=").lines.map(&:strip)
      raise "A compiler is active; cleanup refused" if processes.any? { |path| %w[xcodebuild cargo rustc swift-frontend].include?(File.basename(path)) }
      legacy_caches.each do |path|
        raise "The old cache contains a running app; cleanup refused" if processes.any? { |executable| executable.start_with?(path + "/") }
        # Recheck directory identity immediately before removal; never follow links.
        raise "Cache path changed; cleanup refused" unless File.lstat(path).directory? && File.realpath(path) == path
        puts "Removing superseded Xcode cache: #{path}"
        FileUtils.remove_entry_secure(path)
      end
    end
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
      puts JSON.pretty_generate({ policy: limits, **details, low_space_note: low })
    when "prune", "prune-if-low"
      raise "Cleanup requires macOS" unless RUBY_PLATFORM.include?("darwin")
      raise "Cleanup does not accept a destination" unless destinations.empty?
      prune if command == "prune" || metrics.fetch(:free_bytes) < policy.fetch("warn_free_gib") * GIB
    else raise "Usage: mac_build_budget.rb check|status [DIRECTORY ...] | prune|prune-if-low"
    end
    0
  rescue StandardError => error
    warn "Build storage: #{error.message}"
    75
  end
end

exit MacBuildBudget.main(ARGV) if $PROGRAM_NAME == __FILE__
