# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

module NativeNotices
  PROJECT_URL = "https://github.com/pietro1704/Epub-to-Mp3"
  RELEASE_WORKFLOW = ".github/workflows/release-desktop.yml"
  ESPEAK_SOURCE = "native/vendor/espeak-rs-sys/espeak-ng"
  SONIC_LICENSE = "#{ESPEAK_SOURCE}/src/sonic/LICENSE"
  SONIC_UPSTREAM = "https://github.com/waywardgeek/sonic"
  HISTORICAL_SONIC_PIN = "fbf75c3d6d846bad3bb3d456cbc5d07d9fd8c104"
  # The first vendored LICENSE is byte-identical to LICENSE at the external pin.
  HISTORICAL_SONIC_LICENSE_BLOB = "d645695673349e3947e8e5ae42332d0ac3164cd7"
  SHA = /\A[0-9a-f]{40}\z/
  EXTERNAL_SONIC = %r{
    ^[ \t]*GIT_REPOSITORY[ \t]+#{Regexp.escape(SONIC_UPSTREAM)}\.git[ \t]*\r?\n
    [ \t]*GIT_TAG[ \t]+([0-9a-f]{40})[ \t]*\r?$
  }x
  LICENSE_PATHS = [
    "native/THIRD_PARTY_NOTICES.md",
    "native/licenses/espeak-ng-GPL-3.0.txt",
    "native/vendor/espeak-rs/LICENSE",
    "#{ESPEAK_SOURCE}/src/ucd-tools/COPYING.UCD"
  ].freeze

  module_function

  def stage(repository, sha, destination)
    unless SHA.match?(sha) && git(repository, "rev-parse", "--verify", "#{sha}^{commit}")&.strip == sha
      raise ArgumentError, "Expected an exact release commit (40 hexadecimal characters): #{sha}"
    end
    destination = File.expand_path(destination)
    require_new_destination(destination)

    release_file(repository, sha, RELEASE_WORKFLOW)
    deps = release_file(repository, sha, "#{ESPEAK_SOURCE}/cmake/deps.cmake")
    sonic_pin = deps[EXTERNAL_SONIC, 1]
    files = LICENSE_PATHS.to_h { |path| [path, release_file(repository, sha, path)] }
    files[SONIC_LICENSE] = if sonic_pin
      historical_sonic_license(repository, sonic_pin)
    else
      release_file(repository, sha, SONIC_LICENSE)
    end
    files["SOURCE.md"] = source_note(sha, files.keys, sonic_pin)

    Dir.mktmpdir(".native-notices-", File.dirname(destination)) do |temporary|
      staging = File.join(temporary, "notices")
      files.each do |path, contents|
        target = File.join(staging, path)
        FileUtils.mkdir_p(File.dirname(target))
        File.binwrite(target, contents)
      end
      File.chmod(0o755, staging)
      require_new_destination(destination)
      File.rename(staging, destination)
    end
  end

  def require_new_destination(destination)
    if File.exist?(destination) || File.symlink?(destination)
      raise ArgumentError, "Notice destination already exists: #{destination}"
    end
  end

  def git(repository, *arguments)
    output, _stderr, status = Open3.capture3("git", "--no-replace-objects", "-C", repository, *arguments, binmode: true)
    output if status.success?
  end

  def release_file(repository, sha, path)
    entry = git(repository, "ls-tree", sha, "--", path)
    unless entry&.match?(/\A100(?:644|755) blob /)
      raise ArgumentError, "Required regular source file missing from #{sha}: #{path}"
    end

    contents = git(repository, "cat-file", "blob", "#{sha}:#{path}")
    if contents.nil? || contents.empty?
      raise ArgumentError, "Cannot read a nonempty source file from #{sha}: #{path}"
    end

    contents
  end

  def historical_sonic_license(repository, sonic_pin)
    unless sonic_pin == HISTORICAL_SONIC_PIN
      raise ArgumentError, "Unknown external Sonic license revision: #{sonic_pin}"
    end
    contents = git(repository, "cat-file", "blob", HISTORICAL_SONIC_LICENSE_BLOB)
    raise ArgumentError, "Missing verified historical Sonic license" if contents.nil? || contents.empty?

    contents
  end

  def source_note(sha, paths, sonic_pin)
    note = +<<~MARKDOWN
      # Source and notices

      Source commit: #{sha}

      - [Repository at the exact commit](#{PROJECT_URL}/tree/#{sha})
      - [Corresponding Source archive](#{PROJECT_URL}/archive/#{sha}.tar.gz)
      - [Build and packaging workflow](#{PROJECT_URL}/blob/#{sha}/#{RELEASE_WORKFLOW})

      Packaged notices and licenses and their source locations

    MARKDOWN
    paths.each do |path|
      original = if sonic_pin && path == SONIC_LICENSE
        "#{SONIC_UPSTREAM}/blob/#{sonic_pin}/LICENSE"
      else
        "#{PROJECT_URL}/blob/#{sha}/#{path}"
      end
      note << "- [#{path}](#{path}) · [original](#{original})\n"
    end
    if sonic_pin
      note << "\nThe historical build specifies [an external Sonic fallback at its source commit](#{SONIC_UPSTREAM}/tree/#{sonic_pin}).\n"
    end
    note
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    unless ARGV.length == 3
      raise ArgumentError, "Usage: ruby stage_native_notices.rb REPOSITORY RELEASE_SHA NEW_DIRECTORY"
    end

    NativeNotices.stage(*ARGV)
  rescue ArgumentError, SystemCallError => error
    warn "ERROR: #{error.message}"
    exit 1
  end
end
