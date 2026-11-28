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

  # What cargo compiles into converter-ffi: manifests, build scripts and src
  # trees of its workspace and vendored crates.
  FFI_INPUT_GLOBS = ['Cargo.{toml,lock}'] + %w[crates/converter-core crates/converter-ffi native/* native/vendor/*]
                                             .map { |crate| "#{crate}/{Cargo.toml,build.rs,src/**/*}" }

  # `build` embeds target/release as it is and never runs cargo, so an old dylib
  # yields an app whose newer converter calls fail only at run time.
  def self.verify_ffi_current!(root)
    built = File.mtime(File.join(root, 'target/release/libconverter_ffi.dylib'))
    newest = Dir.glob(FFI_INPUT_GLOBS, base: root).map { |relative| [File.mtime(File.join(root, relative)), relative] if File.file?(File.join(root, relative)) }.compact.max
    return unless newest && newest.first > built

    raise "target/release/libconverter_ffi.dylib is older than #{newest.last}; refusing to embed it. " \
          'Run `mise run converter-ffi:build` first (if cargo reports it fresh, touch crates/converter-ffi/src/lib.rs and run it again)'
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
      'signing_policy' => (configuration == 'Debug' ? 'ad-hoc-no-entitlements' : 'project'),
      'developer' => ENV['DEVELOPER_DIR'] || capture('xcode-select', '-p'), 'xcode' => capture('xcodebuild', '-version'),
      'architecture' => capture('uname', '-m'),
      'flags' => %w[DEVELOPER_DIR TOOLCHAINS SDKROOT ARCHS OTHER_SWIFT_FLAGS OTHER_CFLAGS OTHER_LDFLAGS SWIFT_VERSION SWIFT_ACTIVE_COMPILATION_CONDITIONS MACOSX_DEPLOYMENT_TARGET].to_h { |name| [name, ENV[name]] } }
  end

  # A sandboxed app needs these to work at all: without network.client DNS is
  # denied and model downloads fail with NSURLError -1003; without user-selected
  # file access no open or save panel is displayed.
  SANDBOX_REQUIRED_ENTITLEMENTS = %w[com.apple.security.network.client
                                     com.apple.security.files.user-selected.read-write].freeze

  def self.missing_entitlements(plist_xml)
    granted = plist_xml.scan(%r{<key>([^<]+)</key>\s*<true\s*/>}).flatten
    return [] unless granted.include?('com.apple.security.app-sandbox')

    SANDBOX_REQUIRED_ENTITLEMENTS - granted
  end

  def self.verify_entitlements!(app)
    missing = missing_entitlements(capture('codesign', '-d', '--entitlements', '-', '--xml', app))
    raise "Signed app lacks #{missing.join(', ')}; refusing to launch" unless missing.empty?
  end

  def self.build_command(derived, configuration)
    arguments = ['xcodebuild', '-project', 'EpubToMp3.xcodeproj', '-scheme', 'EpubToMp3Mac',
                 '-configuration', configuration, '-destination', 'platform=macOS',
                 '-derivedDataPath', derived, '-jobs', '1']
    # The project permits unsigned Debug iteration, while GUI validation requires
    # a sealed bundle. Sign this explicit validation build locally with no team.
    if configuration == 'Debug'
      arguments += %w[CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS=]
    end
    arguments + ['build']
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
    options[:derived] ||= ENV['APPLE_DERIVED_DATA_PATH'] if options[:root] == ROOT
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
      capture('codesign', '--verify', '--deep', '--strict', app)
      verify_entitlements!(app)
      run!('open', app)
    when 'build'
      verify_ffi_current!(root)
      status = NativeJob.run(phase: 'build', build_dir: derived, command: [RbConfig.ruby, __FILE__,
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
      NativeJob.build_entrypoint(__FILE__, ['_build', *ARGV], build_dir: derived)
      Dir.chdir(File.join(root, 'ios/EpubToMp3')) do
        MacValidate.run!('xcodegen', 'generate')
        MacValidate.run!(*MacValidate.build_command(derived, configuration))
      end
      exit 0
    end
    exit MacValidate.main(ARGV)
  rescue StandardError => error
    warn "mac validation: #{error.message}"
    exit 1
  end
end
