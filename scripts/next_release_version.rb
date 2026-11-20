# frozen_string_literal: true

# Decide whether the commits since the last release tag warrant a new release and
# which version it is, from Conventional Commit subjects.
#
#   git log v0.5.8..HEAD --format='%s%n%b%x00' | ruby scripts/next_release_version.rb \
#     --last-tag v0.5.8 --committed 0.5.8
#
# Prints `bump=` (none|patch|minor|major|committed) and, unless none, `version=`.
# `committed` means master already carries a version newer than the last tag; the
# Auto Release workflow publishes that one and no release pull request is needed.
module NextReleaseVersion
  Plan = Struct.new(:bump, :version, keyword_init: true)

  CONVENTIONAL = /\A(?<type>[a-z]+)(?:\([^)]*\))?(?<breaking>!)?:\s/
  PATCH_TYPES = %w[fix perf].freeze
  MINOR_TYPES = %w[feat].freeze

  module_function

  def parse(text)
    text.to_s.split(/\x00/).map(&:strip).reject(&:empty?).map do |record|
      subject, body = record.split("\n", 2)
      [subject.to_s, body.to_s]
    end
  end

  def semver(text)
    text.to_s.delete_prefix("v").split(".").map { |part| Integer(part, 10) }
  end

  def level(subjects, bodies)
    levels = subjects.map do |subject|
      match = CONVENTIONAL.match(subject)
      next :none unless match
      next :breaking if match[:breaking]
      next :minor if MINOR_TYPES.include?(match[:type])

      PATCH_TYPES.include?(match[:type]) ? :patch : :none
    end
    levels << :breaking if bodies.any? { |body| body.match?(/^BREAKING[ -]CHANGE:/) }
    %i[breaking minor patch].find { |candidate| levels.include?(candidate) } || :none
  end

  def bumped(last, level)
    major, minor, patch = semver(last)
    case level
    when :breaking then major.zero? ? [major, minor + 1, 0] : [major + 1, 0, 0]
    when :minor then [major, minor + 1, 0]
    else [major, minor, patch + 1]
    end.join(".")
  end

  def plan(last_tag:, committed_version:, subjects:, bodies: [])
    committed = semver(committed_version)
    return Plan.new(bump: "committed", version: committed_version) if last_tag.to_s.empty?
    return Plan.new(bump: "committed", version: committed_version) if (committed <=> semver(last_tag)) == 1

    wanted = level(subjects, bodies)
    return Plan.new(bump: "none", version: nil) if wanted == :none

    bump = wanted == :breaking ? (semver(last_tag).first.zero? ? "minor" : "major") : wanted.to_s
    Plan.new(bump: bump, version: bumped(last_tag, wanted))
  end

  def run(argv, input)
    options = { "--last-tag" => "", "--committed" => nil }
    argv.each_slice(2) { |flag, value| options[flag] = value if options.key?(flag) }
    abort "--committed is required" unless options["--committed"]
    records = parse(input)
    result = plan(last_tag: options["--last-tag"], committed_version: options["--committed"],
                  subjects: records.map(&:first), bodies: records.map(&:last))
    lines = ["bump=#{result.bump}"]
    lines << "version=#{result.version}" if result.version
    puts lines
  end
end

NextReleaseVersion.run(ARGV, $stdin.read) if $PROGRAM_NAME == __FILE__
