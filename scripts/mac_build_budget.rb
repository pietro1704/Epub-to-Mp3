# frozen_string_literal: true

require "json"
require "open3"
require "fileutils"

# Build storage only: books, models, app data, tools and evidence are excluded.
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
    %w[minimum_free_gib maximum_cache_gib check_interval_seconds].each do |key|
      raise "Invalid build budget #{key}" unless value[key].is_a?(Integer) && value[key].positive?
    end
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

  def self.disk_usage(paths)
    identities = paths.to_h do |path|
      stat = File.lstat(path)
      raise "Cache root is not a directory" unless stat.directory?
      [path, [stat.dev, stat.ino]]
    end
    output, error, status = Open3.capture3("du", "-sk", *paths)
    rows = output.lines.map { |line| line.chomp.split("\t", 2) }
    complete = rows.length == paths.length && rows.map(&:last).uniq.length == paths.length &&
               rows.all? { |quantity, path| quantity.match?(/\A\d+\z/) && paths.include?(path) }
    raise "Incomplete cache disk-usage summaries" unless complete
    unchanged = paths.all? do |path|
      stat = File.lstat(path)
      stat.directory? && [stat.dev, stat.ino] == identities.fetch(path)
    end
    raise "Cache root identity changed during inspection" unless unchanged
    unless status.success?
      # A compiler may unlink its temporary child during traversal. Accept only
      # vanished descendants with complete summaries for unchanged cache roots.
      errors = error.lines.map(&:chomp)
      vanished = status.exitstatus == 1 && !errors.empty? && errors.all? do |line|
        match = line.match(/\Adu: (.+): No such file or directory\z/)
        next false unless match
        child = match[1]
        File.expand_path(child) == child && paths.any? { |path| child.start_with?(path + "/") } &&
          !File.exist?(child) && !File.symlink?(child)
      end
      raise "du inspection failed: #{error.strip}" unless vanished
    end
    rows.sum { |quantity, _| Integer(quantity) * 1024 }
  end

  def self.metrics
    free = Integer(capture("df", "-Pk", ROOT).lines.last.split.fetch(3)) * 1024
    paths = worktrees.flat_map do |root|
      [File.join(root, "target"), *Dir.glob(File.join(root, ".build*")),
       *Dir.glob(File.join(root, "ios/EpubToMp3/.build*"))]
    end
    paths = (paths + xcode_caches).select { |path| File.directory?(path) }.map { |path| File.realpath(path) }.uniq
    used = paths.empty? ? 0 : disk_usage(paths)
    { free_bytes: free, cache_bytes: used, paths: paths }
  end

  def self.evaluate(limits, free_bytes:, cache_bytes:, **)
    return "Free disk below #{limits.fetch('minimum_free_gib')} GiB; build blocked." if free_bytes < limits.fetch("minimum_free_gib") * GIB
    return "Project build caches exceed #{limits.fetch('maximum_cache_gib')} GiB; build blocked. Inspect build:storage before pruning obsolete caches." if cache_bytes > limits.fetch("maximum_cache_gib") * GIB
    nil
  end

  def self.check(host: RUBY_PLATFORM)
    return nil unless host.include?("darwin")
    evaluate(policy, **metrics)
  rescue StandardError => error
    "Build storage inspection failed (#{error.class}: #{error.message}); build blocked."
  end

  def self.interval(host: RUBY_PLATFORM)
    host.include?("darwin") ? policy.fetch("check_interval_seconds") : 10
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
    if arguments == ["check"]
      error = check
      warn error if error
      return error ? 75 : 0
    end
    raise "Mac build storage commands require macOS" unless RUBY_PLATFORM.include?("darwin")
    case arguments
    when ["status"]
      limits = policy
      snapshot = metrics
      puts JSON.pretty_generate({ policy: limits, **snapshot, blocked: evaluate(limits, **snapshot) })
    when ["prune"] then prune
    when ["prune-if-low"] then prune if metrics.fetch(:free_bytes) < policy.fetch("minimum_free_gib") * GIB
    else raise "Usage: mac_build_budget.rb check|status|prune|prune-if-low"
    end
    0
  rescue StandardError => error
    warn "Build storage: #{error.message}"
    75
  end
end

exit MacBuildBudget.main(ARGV) if $PROGRAM_NAME == __FILE__
