# frozen_string_literal: true

require "open3"

# Read Xcode's existing workspace identity; never move, clean or create a cache.
module XcodeBuildPaths
  ROOT = File.expand_path("..", __dir__)
  DEVELOPER = "/Applications/Xcode-16.4.0.app/Contents/Developer"
  HOSTED_DEVELOPER = "/Applications/Xcode_16.4.app/Contents/Developer"
  IPHONE_16E_DEVICE = '44B2CFBD-2193-5086-8E8D-BF7A2876C321'
  IPHONE_16E_DEVELOPER = '/Applications/Xcode-26.3.0.app/Contents/Developer'

  def self.developer(environment: ENV, directory: ->(path) { File.directory?(path) })
    if environment['IOS_DEVICE_ID'] == IPHONE_16E_DEVICE
      return IPHONE_16E_DEVELOPER if directory.call(IPHONE_16E_DEVELOPER)
      raise "Xcode 26.3 is required for the physical iPhone 16e at #{IPHONE_16E_DEVELOPER}"
    end
    [DEVELOPER, HOSTED_DEVELOPER].find { |path| directory.call(path) } ||
      raise("Xcode 16.4 is required at #{DEVELOPER} or #{HOSTED_DEVELOPER}")
  end

  def self.device_app(environment: ENV)
    override = environment['IOS_DERIVED_DATA_PATH']
    override = nil if override&.empty?
    cache = File.expand_path(override || environment.fetch('APPLE_DERIVED_DATA_PATH'))
    candidates = Dir.glob(File.join(cache, 'Build/Products/*-iphoneos/EpubToMp3.app'))
                    .select { |path| File.directory?(path) }
    candidates.max_by { |path| File.mtime(path) } ||
      raise("No existing iphoneos EpubToMp3.app in #{cache}")
  end

  def self.derived_data(root: ROOT, home: Dir.home, environment: ENV,
                        reader: ->(path) { Open3.capture3("plutil", "-extract", "WorkspacePath", "raw", "-o", "-", path) })
    explicit = environment["APPLE_DERIVED_DATA_PATH"]
    return File.expand_path(explicit, root) if explicit && !explicit.empty?

    project = File.join(root, "ios/EpubToMp3/EpubToMp3.xcodeproj")
    candidates = Dir.glob(File.join(home, "Library/Developer/Xcode/DerivedData/*/info.plist")).map do |info|
      output, error, status = reader.call(info)
      raise "Cannot read Xcode cache identity #{info}: #{error.strip}" unless status.success?
      workspace = output.strip
      next unless !workspace.empty? && File.expand_path(workspace) == File.expand_path(project)
      [File.mtime(info), File.dirname(info)]
    end.compact
    candidates.max_by(&:first)&.last || File.join(root, "ios/EpubToMp3/.build")
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    case ARGV
    when ["developer"]
      puts XcodeBuildPaths.developer
    when ["derived-data"] then puts XcodeBuildPaths.derived_data
    when ["device-app"] then puts XcodeBuildPaths.device_app
    else raise "Usage: xcode_build_paths.rb developer|derived-data|device-app"
    end
  rescue StandardError => error
    warn "Xcode build paths: #{error.message}"
    exit 75
  end
end
