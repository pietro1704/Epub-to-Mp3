#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'tmpdir'
require_relative 'native_job'

# A narrow Apple-only path: inspection never builds, packaging never compiles,
# and an explicit incremental build never invokes the Rust task dependency.
module MacValidate
  ROOT = File.expand_path('..', __dir__)
  MODES = %w[inspect package build gui].freeze

  def self.capture(*command)
    out, error, status = Open3.capture3(*command)
    raise "#{command.first} failed: #{error.strip}" unless status.success?
    out.strip
  end

  def self.run!(*command)
    raise "#{command.first} failed" unless system(*command)
  end

  def self.identity(root, configuration)
    project = File.join(root, 'ios/EpubToMp3')
    files = %w[EpubToMp3 EpubToMp3ShareExtension EpubToMp3Widget].flat_map do |directory|
      Dir.glob(File.join(project, directory, '**/*')).select { |path| File.file?(path) }
    end
    files += Dir.glob(File.join(project, '*.{yml,xcconfig}'))
    files += Dir.glob(File.join(root, 'scripts/bundle_*'))
    files += %w[prepare_onnxruntime_macos.rb fetch_onnxruntime_macos.rb].map { |name| File.join(root, 'scripts', name) }.select { |path| File.file?(path) }
    files += Dir.glob(File.join(root, 'crates/**/*.{rs,toml}'))
    files += Dir.glob(File.join(root, 'native/**/*.{rs,toml}'))
    files += Dir.glob(File.join(root, 'target/onnxruntime-macos-prebuilt/*/{runtime.json,lib/libonnxruntime.dylib}'))
    files += %w[Cargo.toml Cargo.lock].map { |path| File.join(root, path) }
    files << File.join(root, 'target/release/libconverter_ffi.dylib')
    digests = files.sort.to_h { |path| [path.delete_prefix(root + '/'), Digest::SHA256.file(path).hexdigest] }
    { 'sources' => digests, 'root' => File.realpath(root), 'configuration' => configuration,
      'destination' => 'platform=macOS', 'scheme' => 'EpubToMp3Mac', 'jobs' => 1,
      'developer' => capture('xcode-select', '-p'), 'xcode' => capture('xcodebuild', '-version'),
      'architecture' => capture('uname', '-m'),
      'flags' => %w[DEVELOPER_DIR TOOLCHAINS SDKROOT ARCHS OTHER_SWIFT_FLAGS OTHER_CFLAGS OTHER_LDFLAGS SWIFT_VERSION SWIFT_ACTIVE_COMPILATION_CONDITIONS MACOSX_DEPLOYMENT_TARGET].to_h { |name| [name, ENV[name]] } }
  end

  def self.product_hashes(app)
    raise 'Missing app executable' unless File.file?(File.join(app, 'Contents/MacOS/EpubToMp3'))
    Dir.glob(File.join(app, '**/*')).select { |path| File.file?(path) }.sort.to_h do |path|
      [path.delete_prefix(app + '/'), Digest::SHA256.file(path).hexdigest]
    end
  end

  def self.compatible?(receipt, expected, app)
    stored = JSON.parse(File.read(receipt))
    stored == { 'identity' => expected, 'products' => product_hashes(app) }
  rescue Errno::ENOENT, JSON::ParserError
    false
  end

  def self.package(root, app, arch)
    raise 'Unsupported architecture' unless %w[x86_64 arm64].include?(arch)
    ffi = File.join(app, 'Contents/Frameworks/libconverter_ffi.dylib')
    raise 'Missing embedded converter-ffi' unless File.file?(ffi)
    # All mutation is confined to a disposable fixture; user products remain intact.
    script = File.join(root, 'scripts/bundle_onnxruntime_apple.sh')
    raise 'Checkout bundler differs from current validation tool' unless Digest::SHA256.file(script).hexdigest == Digest::SHA256.file(File.join(ROOT, 'scripts/bundle_onnxruntime_apple.sh')).hexdigest
    runtime = File.join(root, 'target/onnxruntime-macos-prebuilt', arch, 'lib/libonnxruntime.dylib')
    original = Digest::SHA256.file(ffi).hexdigest
    runtime_original = Digest::SHA256.file(runtime).hexdigest
    Dir.mktmpdir('mac-packaging-') do |temporary|
      frameworks = File.join(temporary, 'Fixture.app/Contents/Frameworks')
      FileUtils.mkdir_p(frameworks)
      FileUtils.cp(ffi, frameworks)
      script = File.join(root, 'scripts/bundle_onnxruntime_apple.sh')
      out, error, status = Open3.capture3({ 'PLATFORM_NAME' => 'macosx', 'ARCHS' => arch,
        'TARGET_BUILD_DIR' => temporary, 'FRAMEWORKS_FOLDER_PATH' => 'Fixture.app/Contents/Frameworks',
        'EXPANDED_CODE_SIGN_IDENTITY' => '-' }, '/bin/bash', script)
      raise "Packaging failed: #{out}\n#{error}" unless status.success?
      raise "Packaging invalidated an existing signature: #{error}" if error.include?('will invalidate the code signature')
      libraries = Dir.glob(File.join(frameworks, 'libonnxruntime*.dylib'))
      raise 'Fixture does not exercise dynamic ONNX packaging' if libraries.empty?
      libraries.each { |library| capture('codesign', '--verify', '--strict', library) }
      raise 'Original ONNX runtime changed' unless Digest::SHA256.file(runtime).hexdigest == runtime_original
      raise 'Original converter changed' unless Digest::SHA256.file(ffi).hexdigest == original
      puts JSON.generate('result' => 'passed', 'mode' => 'package', 'source_sha256' => original,
                         'runtime_libraries' => libraries.map { |path| File.basename(path) })
    end
  end

  def self.main(arguments)
    options = { root: ROOT, configuration: 'Debug', mode: 'inspect' }
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: mac_validate.rb [inspect|package|build|gui] --derived-data PATH [--project-root PATH]'
      opts.on('--derived-data PATH') { |value| options[:derived] = File.expand_path(value) }
      opts.on('--project-root PATH', '--checkout PATH') { |value| options[:root] = File.realpath(value) }
      opts.on('--configuration NAME', %w[Debug Release]) { |value| options[:configuration] = value }
    end
    options[:mode] = arguments.shift if MODES.include?(arguments.first)
    parser.parse!(arguments)
    raise parser.to_s unless arguments.empty? && options[:derived]
    root, derived, configuration = options.values_at(:root, :derived, :configuration)
    app = File.join(derived, 'Build/Products', configuration, 'EpubToMp3.app')
    receipt = File.join(derived, "mac-validation-#{configuration}.json")
    if options[:mode] == 'package'
      package(root, app, capture('uname', '-m'))
      return 0
    end
    begin
      expected = identity(root, configuration)
      compatible = compatible?(receipt, expected, app)
    rescue StandardError => error
      raise unless options[:mode] == 'inspect'
      puts JSON.generate('mode' => 'inspect', 'app' => app, 'compatible' => false, 'reason' => error.message)
      return 0
    end
    case options[:mode]
    when 'inspect'
      puts JSON.generate('mode' => 'inspect', 'app' => app, 'compatible' => compatible,
                         'reason' => compatible ? 'Verified build receipt' : 'Build identity unknown or changed; no build or launch performed')
    when 'gui'
      raise 'Build identity unknown or changed; use explicit incremental build before GUI validation' unless compatible
      preflight = NativeBuildPreflight.check
      raise "GUI launch refused: #{preflight}" if preflight
      capture('codesign', '--verify', '--deep', '--strict', app)
      run!('open', app)
    when 'build'
      # Existing DerivedData is mandatory: no hidden second project cache.
      raise 'DerivedData directory must already exist' unless File.directory?(derived)
      status = NativeJob.run(phase: 'build', command: [RbConfig.ruby, __FILE__,
        '_build', root, derived, configuration])
      return status unless status.zero?
      raise 'Sources changed during build' unless identity(root, configuration) == expected
      File.write(receipt, JSON.pretty_generate('identity' => expected, 'products' => product_hashes(app)))
    end
    0
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    if ARGV.first == '_build'
      ARGV.shift
      root, derived, configuration = ARGV
      raise 'Invalid guarded build arguments' unless ARGV.length == 3 && %w[Debug Release].include?(configuration)
      # This private child entrypoint also authenticates the inherited lease.
      NativeJob.build_entrypoint(__FILE__, ['_build', *ARGV])
      Dir.chdir(File.join(root, 'ios/EpubToMp3')) do
        MacValidate.run!('xcodegen', 'generate')
        MacValidate.run!('xcodebuild', '-project', 'EpubToMp3.xcodeproj', '-scheme', 'EpubToMp3Mac',
          '-configuration', configuration, '-destination', 'platform=macOS', '-derivedDataPath', derived,
          '-jobs', '1', 'build')
      end
      exit 0
    end
    exit MacValidate.main(ARGV)
  rescue StandardError => error
    warn "mac validation: #{error.message}"
    exit 1
  end
end
