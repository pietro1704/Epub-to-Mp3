#!/usr/bin/env ruby
# frozen_string_literal: true

# Hosted Linux GUI artifact evidence for .github/workflows/linux-gui-artifact.yml:
#   snapshot  - record tracked generated-source provenance before building
#   build-cpu - print the lowest CPU this process may run on (taskset pinning)
#   audit     - audit the normal Flutter bundle and archive it with identity evidence
# Checks, messages and outputs mirror the former inline Python step by step.
require 'digest'
require 'etc'
require 'fileutils'
require 'json'
require 'open3'
require_relative 'python_archive_formats'
require_relative 'python_json'

module LinuxGuiArtifactEvidence
  class Error < PythonFormats::Error; end

  GENERATED_PATHS = %w[flutter_app/lib/l10n/app_localizations.dart
                       flutter_app/lib/l10n/app_localizations_en.dart].freeze
  PROVENANCE_PATHS = (GENERATED_PATHS + ['voice_samples/README.md']).freeze
  EVIDENCE = '.reports/linux-gui'
  PRODUCT = '.reports/linux-gui-product'
  BUNDLE = 'flutter_app/build/linux/x64/release/bundle'
  ARCHIVE = 'epub-to-mp3-flutter-linux-x86_64.tar.gz'
  ARCHIVE_ROOT = 'epub-to-mp3-linux'
  FORBIDDEN_SUFFIXES = %w[.onnx .epub .pdf .mp3 .wav .safetensors .gguf].freeze
  REQUIRED_ASSETS = %w[phontab phondata phonindex lang/roa/pt].freeze
  REQUIRED_SYMBOLS = %w[converter_session_open converter_session_free
                        converter_session_set_desktop_platform_tts_v1
                        converter_session_convert_streaming_job_options_json_v1
                        converter_book_library_metadata_json_v1
                        converter_string_free].freeze

  # subprocess.run(check=True, capture_output=True, text=True, timeout=60) and
  # subprocess.check_output equivalents running in the repository root.
  class Shell
    def initialize(root:, environment:, timeout: 60)
      @root = root
      @environment = environment
      @timeout = timeout
    end

    def text(argv, extra_environment = {})
      output = capture(argv, @environment.merge(extra_environment)).force_encoding(Encoding::UTF_8)
      raise Error, "Command '#{argv.join(' ')}' produced non-UTF-8 output" unless output.valid_encoding?

      output.gsub(/\r\n?/, "\n")
    end

    def bytes(argv)
      output, status = Open3.capture2(@environment, *argv, chdir: @root, binmode: true,
                                                           unsetenv_others: true)
      raise Error, failure(argv, status) unless status.success?

      output
    end

    private

    def capture(argv, environment)
      Open3.popen3(environment, *argv, chdir: @root, unsetenv_others: true) do |input, output, error, waiter|
        input.close
        readers = [output, error].map { |stream| Thread.new { stream.binmode.read } }
        unless waiter.join(@timeout)
          terminate(waiter.pid)
          waiter.join
          raise Error, "Command '#{argv.join(' ')}' timed out after #{@timeout} seconds"
        end
        stdout, stderr = readers.map(&:value)
        raise Error, "#{failure(argv, waiter.value)}\n#{stderr}".rstrip unless waiter.value.success?

        stdout
      end
    end

    def terminate(pid)
      Process.kill('KILL', pid)
    rescue Errno::ESRCH
      nil
    end

    def failure(argv, status)
      "Command '#{argv.join(' ')}' returned non-zero exit status #{status.exitstatus || status.termsig}."
    end
  end

  module_function

  def sha256(path) = Digest::SHA256.file(path).hexdigest

  def regular?(path) = !File.symlink?(path) && File.file?(path)

  def write_json(path, value) = File.write(path, PythonJson.dump(value, indent: 2))

  def changed_paths(text) = text.split("\0").reject(&:empty?)

  # pathlib.PurePath.suffix: the final dotted part of the name, never a dotfile name.
  def suffix(name)
    index = name.rindex('.')
    index&.positive? && index < name.length - 1 ? name[index..] : ''
  end

  def snapshot(root:, environment: ENV.to_h)
    shell = Shell.new(root: root, environment: environment)
    changed = changed_paths(shell.bytes(%w[git diff --name-only -z HEAD]).force_encoding(Encoding::UTF_8))
    raise Error, 'Unexpected tracked changes before building' unless (changed - PROVENANCE_PATHS).empty?

    records = PROVENANCE_PATHS.to_h do |name|
      path = File.join(root, name)
      raise Error, "Expected regular provenance input: #{name}" unless regular?(path)

      head = shell.bytes(['git', 'show', "HEAD:#{name}"])
      [name, { 'headSha256' => Digest::SHA256.hexdigest(head),
               'rawBeforeSha256' => Digest::SHA256.hexdigest(File.binread(path)) }]
    end
    evidence = File.join(root, EVIDENCE)
    FileUtils.mkdir_p(evidence)
    source = shell.bytes(%w[git rev-parse HEAD]).force_encoding(Encoding::UTF_8).strip
    write_json(File.join(evidence, 'source-before.json'), { 'sourceCommit' => source, 'files' => records })
  end

  # min(os.sched_getaffinity(0)) through the kernel's allowed-CPU list.
  def build_cpu(status_path = '/proc/self/status')
    line = File.exist?(status_path) && File.foreach(status_path).find { |row| row.start_with?('Cpus_allowed_list:') }
    raise Error, "CPU affinity is unavailable: no Cpus_allowed_list in #{status_path}" unless line

    cpus = line.split(':', 2).fetch(1).strip.split(',').map do |part|
      match = /\A(\d+)(?:-(\d+))?\z/.match(part)
      raise Error, "Unparseable Cpus_allowed_list entry #{part.inspect} in #{status_path}" unless match

      [Integer(match[1], 10), Integer(match[2] || match[1], 10)].min
    end
    raise Error, "CPU affinity is unavailable: empty Cpus_allowed_list in #{status_path}" if cpus.empty?

    cpus.min
  end

  # The former inline Python audit, check by check and in the same order.
  class Audit
    def initialize(root:, environment: ENV.to_h, uname: Etc.uname, gzip_mtime: nil)
      @root = root
      @environment = environment
      @uname = uname
      @gzip_mtime = gzip_mtime
      @shell = Shell.new(root: root, environment: environment)
      @bundle = File.join(root, BUNDLE)
      @evidence = File.join(root, EVIDENCE)
      @product = File.join(root, PRODUCT)
    end

    def run
      Dir.mkdir(@product)
      unless File.directory?(@bundle) && File.realpath(@bundle) == @bundle
        raise Error, 'Normal app bundle is missing or noncanonical'
      end

      source = @shell.text(%w[git rev-parse HEAD]).strip
      unless source == @environment.fetch('EVENT_HEAD_SHA') && source.match?(/\A[0-9a-f]{40}\z/)
        raise Error, 'Checked-out source differs from the requested head'
      end

      provenance = record_provenance(source)
      paths = bundle_paths
      records = manifest(paths)
      binaries = verify_contents
      elf_audit = audit_elves(paths)
      archive_hash = write_archive(paths)
      write_identity(source, provenance, records, elf_audit, binaries, archive_hash)
    end

    private

    def digest(path) = LinuxGuiArtifactEvidence.sha256(path)

    def record_provenance(source)
      before_path = File.join(@evidence, 'source-before.json')
      provenance = JSON.parse(File.read(before_path), allow_nan: true)
      unless provenance.fetch('sourceCommit') == source
        raise Error, 'Pre-build source identity differs from the audited head'
      end
      unless provenance.fetch('files').keys.sort == PROVENANCE_PATHS.sort
        raise Error, 'Unexpected pre-build provenance inputs'
      end

      @tracked_changes = LinuxGuiArtifactEvidence.changed_paths(@shell.text(%w[git diff --name-only -z HEAD]))
      raise Error, 'Unexpected tracked changes after building' unless (@tracked_changes - PROVENANCE_PATHS).empty?

      provenance.fetch('files').each do |name, record|
        path = File.join(@root, name)
        raise Error, "Expected regular provenance output: #{name}" unless LinuxGuiArtifactEvidence.regular?(path)

        record['rawAfterSha256'] = digest(path)
      end
      @patch = File.join(@product, 'generated-localizations.patch')
      File.binwrite(@patch, @shell.bytes(%w[git diff --no-ext-diff --no-textconv --binary HEAD --] + GENERATED_PATHS))
      provenance.merge!('sourceDescription' => 'HEAD plus recorded generated-localizations patch',
                        'generatedPatch' => File.basename(@patch), 'generatedPatchSha256' => digest(@patch),
                        'beforeSnapshotSha256' => digest(before_path))
      @provenance_path = File.join(@product, 'generated-source-provenance.json')
      LinuxGuiArtifactEvidence.write_json(@provenance_path, provenance)
      provenance
    end

    # [bundle, *sorted(bundle.rglob('*'))]: pathlib orders by path components
    # and rglob does not descend into symlinked directories.
    def bundle_paths
      found = []
      walk = lambda do |relative|
        Dir.children(File.join(@bundle, relative)).each do |child|
          entry = relative.empty? ? child : "#{relative}/#{child}"
          found << entry
          walk.call(entry) if File.lstat(File.join(@bundle, entry)).directory?
        end
      end
      walk.call('')
      [{ absolute: @bundle, relative: '.' }] + found.sort_by { |entry| entry.split('/') }.map do |entry|
        { absolute: File.join(@bundle, entry), relative: entry }
      end
    end

    def manifest(paths)
      paths.map do |path|
        absolute = path.fetch(:absolute)
        relative = path.fetch(:relative)
        info = File.lstat(absolute)
        parts = relative == '.' ? [] : relative.split('/')
        if relative.include?('\\') || parts.any? { |part| %w[. ..].include?(part) }
          raise Error, "Unsafe bundle path: #{relative}"
        end
        raise Error, "Unsupported bundle member type: #{relative}" unless info.file? || info.directory?
        if FORBIDDEN_SUFFIXES.include?(LinuxGuiArtifactEvidence.suffix(File.basename(absolute)).downcase)
          raise Error, "Unexpected model, book or audio payload: #{relative}"
        end

        record = { 'path' => relative, 'type' => info.file? ? 'file' : 'directory',
                   'mode' => "0o#{(info.mode & 0o7777).to_s(8)}" }
        record.merge!('bytes' => info.size, 'sha256' => digest(absolute)) if info.file?
        record
      end
    end

    def verify_contents
      executable = File.join(@bundle, 'flutter_app')
      library = File.join(@bundle, 'lib/libconverter_ffi.so')
      unless File.file?(executable) && File.executable_real?(executable) && File.file?(library)
        raise Error, 'Missing normal app executable or embedded Rust library'
      end

      compiled = File.join(@root, 'target/flutter-Linux-x86_64/release/libconverter_ffi.so')
      unless File.file?(compiled) && digest(compiled) == digest(library)
        raise Error, 'Bundle Rust library differs from this task output'
      end

      REQUIRED_ASSETS.each do |name|
        path = File.join(@bundle, 'data/espeak-ng-data', name)
        raise Error, "Missing packaged phoneme asset: #{name}" unless File.file?(path) && File.size(path).positive?
      end
      exports = @shell.text(['nm', '-D', '--defined-only', library])
      REQUIRED_SYMBOLS.each do |symbol|
        raise Error, "Missing packaged ABI: #{symbol}" unless exports.match?(/\b#{Regexp.escape(symbol)}$/)
      end
      [executable, library]
    end

    def audit_elves(paths)
      loader = { 'LD_LIBRARY_PATH' => File.join(@bundle, 'lib') }
      audit = paths.filter_map do |path|
        absolute = path.fetch(:absolute)
        next unless File.file?(absolute) && File.open(absolute, 'rb') { |file| file.read(4) } == "\x7fELF".b

        elf_record(absolute, path.fetch(:relative), loader)
      end
      unless (%w[flutter_app lib/libconverter_ffi.so] - audit.map { |entry| entry.fetch('path') }).empty?
        raise Error, 'Critical app or Rust library was not audited as ELF'
      end
      raise Error, 'Unexpected verification host' unless @uname[:sysname] == 'Linux' && @uname[:machine] == 'x86_64'

      audit
    end

    def elf_record(absolute, relative, loader)
      header = @shell.text(['readelf', '--file-header', absolute])
      unless header.match?(/Class:\s+ELF64/) && header.match?(/Machine:\s+Advanced Micro Devices X86-64/)
        raise Error, "Expected ELF64 x86_64: #{relative}"
      end

      needed = @shell.text(['readelf', '--dynamic', absolute]).scan(/\(NEEDED\).*?\[([^\]]+)\]/).map(&:first)
      if needed.any? { |name| name.include?('onnxruntime') }
        raise Error, 'Linux product unexpectedly requires dynamic ONNX Runtime'
      end

      closure = needed.empty? ? '' : @shell.text(['ldd', absolute], loader)
      raise Error, "Unresolved ELF dependency: #{relative}" if closure.include?('not found')

      { 'path' => relative, 'needed' => needed, 'resolvedDependencies' => closure }
    end

    def write_archive(paths)
      archive = File.join(@product, ARCHIVE)
      gzip = PythonFormats::GzipWriter.new(archive, mtime: @gzip_mtime)
      tar = PythonFormats::TarWriter.new(gzip)
      paths.each do |path|
        relative = path.fetch(:relative)
        name = relative == '.' ? ARCHIVE_ROOT : "#{ARCHIVE_ROOT}/#{relative}"
        info = File.stat(path.fetch(:absolute))
        if info.directory?
          tar.add_directory(name, info.mode & 0o7777)
        else
          tar.add_file(name, info.mode & 0o7777, path.fetch(:absolute), info.size)
        end
      end
      tar.close
      gzip.close
      archive_hash = digest(archive)
      File.write("#{archive}.sha256", "#{archive_hash}  #{ARCHIVE}\n")
      archive_hash
    end

    def write_identity(source, provenance, records, elf_audit, binaries, archive_hash)
      executable, library = binaries
      files = File.join(@product, 'files.json')
      LinuxGuiArtifactEvidence.write_json(files, records)
      environment = @environment
      identity = {
        'sourceCommit' => source, 'eventHeadCommit' => environment.fetch('EVENT_HEAD_SHA'),
        'eventName' => environment.fetch('GITHUB_EVENT_NAME'), 'runId' => environment.fetch('GITHUB_RUN_ID'),
        'runAttempt' => environment.fetch('GITHUB_RUN_ATTEMPT'), 'architecture' => @uname[:machine],
        'target' => 'lib/main.dart', 'task' => 'mise run flutter:build-linux',
        'cargoTargetDirectory' => 'target/flutter-Linux-x86_64',
        'flags' => { 'CARGO_BUILD_JOBS' => 1, 'CMAKE_BUILD_PARALLEL_LEVEL' => 1, 'ORT_PREFER_DYNAMIC_LINK' => 0,
                     'buildCpu' => Integer(File.read(File.join(@evidence, 'build-cpu.txt')).strip, 10) },
        'toolchains' => toolchains,
        'cargoLockSha256' => digest(File.join(@root, 'Cargo.lock')),
        'executableSha256' => digest(executable), 'embeddedLibrarySha256' => digest(library),
        'archive' => ARCHIVE, 'archiveSha256' => archive_hash,
        'filesManifestSha256' => digest(files), 'elfAudit' => elf_audit,
        'dependencyAuditLibraryPath' => File.join(@bundle, 'lib'),
        'trackedChangesAfterBuild' => @tracked_changes,
        'sourceDescription' => provenance.fetch('sourceDescription'),
        'generatedSourceProvenance' => File.basename(@provenance_path),
        'generatedSourceProvenanceSha256' => digest(@provenance_path),
        'generatedSourcePatch' => File.basename(@patch), 'generatedSourcePatchSha256' => digest(@patch),
        'modelsIncluded' => false, 'applicationLaunched' => false,
        'guiAcceptancePerformed' => false, 'privateBookTestsExecuted' => false
      }
      LinuxGuiArtifactEvidence.write_json(File.join(@product, 'build-identity.json'), identity)
    end

    def toolchains
      { 'rust' => @shell.text(%w[rustc -vV]), 'ruby' => @shell.text(%w[ruby --version]),
        'flutter' => JSON.parse(@shell.text(%w[flutter --version --machine]), allow_nan: true),
        'cmake' => @shell.text(%w[cmake --version]) }
    end
  end

  def main(argv, root: Dir.pwd, environment: ENV.to_h, out: $stdout)
    case argv
    in ['snapshot'] then snapshot(root: root, environment: environment)
    in ['build-cpu'] then out.puts(build_cpu)
    in ['audit'] then Audit.new(root: root, environment: environment).run
    else
      warn 'usage: linux_gui_artifact_evidence.rb snapshot|build-cpu|audit'
      return 2
    end
    0
  rescue PythonFormats::Error => e
    warn "linux_gui_artifact_evidence: #{e.message}"
    1
  end
end

exit(LinuxGuiArtifactEvidence.main(ARGV)) if $PROGRAM_NAME == __FILE__
