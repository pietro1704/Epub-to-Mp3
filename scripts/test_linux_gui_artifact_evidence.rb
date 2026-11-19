# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'yaml'
require 'digest'
require 'json'
require 'zlib'
require 'rbconfig'
require_relative 'linux_gui_artifact_evidence'

class LinuxGuiArtifactEvidenceTest < Minitest::Test
  REPOSITORY = File.expand_path('..', __dir__)
  SCRIPT = File.join(__dir__, 'linux_gui_artifact_evidence.rb')
  WORKFLOW = File.join(REPOSITORY, '.github/workflows/linux-gui-artifact.yml')
  BUNDLE = LinuxGuiArtifactEvidence::BUNDLE
  LINUX = { sysname: 'Linux', machine: 'x86_64' }.freeze
  ELF = "\x7fELF\x02\x01\x01".b
  LONG = "data/flutter_assets/packages/#{'nested_directory_' * 4}/#{'long_asset_name_' * 3}.txt"
  FAKE_TOOLS = {
    'nm' => <<~'SH',
      for symbol in converter_session_open converter_session_free converter_session_set_desktop_platform_tts_v1 \
        converter_session_convert_streaming_job_options_json_v1 converter_book_library_metadata_json_v1 converter_string_free; do
        [ "$symbol" = "${FAKE_NM_OMIT:-}" ] || printf '0000000000001000 T %s\n' "$symbol"
      done
    SH
    'readelf' => <<~'SH',
      case "$1:$2" in
        --file-header:*) printf '  Class:                             ELF64\n  Machine:                           Advanced Micro Devices X86-64\n' ;;
        --dynamic:*/flutter_app) printf ' 0x1 (NEEDED)  Shared library: [libconverter_ffi.so]\n 0x1 (NEEDED)  Shared library: [libc.so.6]\n' ;;
        *) printf ' 0xe (SONAME)  Library soname: [libconverter_ffi.so]\n' ;;
      esac
    SH
    'ldd' => %(printf '\\tlibconverter_ffi.so => %s/libconverter_ffi.so (0x0)\\n' "$LD_LIBRARY_PATH"\n),
    'rustc' => %(printf 'rustc 1.95.0\\nhost: x86_64-unknown-linux-gnu\\n'\n),
    'flutter' => "cat <<'JSON'\n{\"frameworkVersion\":\"3.41.0\",\"note\":\"caf\\u00e9 \\ud83d\\ude00\"}\nJSON\n",
    'cmake' => %(printf 'cmake version 3.28.3\\n'\n)
  }.freeze

  def setup
    @root = File.realpath(Dir.mktmpdir('linux gui evidence '))
    @bin = File.join(@root, '.fake-bin')
    FAKE_TOOLS.each { |name, body| write_file(File.join('.fake-bin', name), body, 0o755, shebang: true) }
    LinuxGuiArtifactEvidence::PROVENANCE_PATHS.each { |path| write_file(path, "head #{path}\n") }
    write_file('Cargo.lock', "# lock\n")
    @env = ENV.to_h.merge('PATH' => "#{@bin}:#{File.dirname(RbConfig.ruby)}:#{ENV.fetch('PATH')}",
                          'GIT_CONFIG_NOSYSTEM' => '1', 'GIT_CONFIG_GLOBAL' => '/dev/null',
                          'GITHUB_EVENT_NAME' => 'workflow_dispatch', 'GITHUB_RUN_ID' => '42',
                          'GITHUB_RUN_ATTEMPT' => '1')
    git('init', '--initial-branch=master')
    git('config', 'user.name', 'Fixture')
    git('config', 'user.email', 'fixture@example.invalid')
    FileUtils.mkdir_p(File.join(@root, '.git/info'))
    File.write(File.join(@root, '.git/info/exclude'), ".fake-bin/\n.reports/\nflutter_app/build/\ntarget/\n")
    git('add', '-A')
    git('commit', '-m', 'fixture')
    @head = git('rev-parse', 'HEAD').strip
    @env['EVENT_HEAD_SHA'] = @head
    write_file(LinuxGuiArtifactEvidence::GENERATED_PATHS.first, "generated\n")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_snapshot_cli_writes_python_formatted_provenance
    _output, error, status = run_cli('snapshot')
    assert status.success?, error
    files = LinuxGuiArtifactEvidence::PROVENANCE_PATHS.map do |path|
      head = Digest::SHA256.hexdigest("head #{path}\n")
      raw = Digest::SHA256.hexdigest(File.binread(File.join(@root, path)))
      %(    "#{path}": {\n      "headSha256": "#{head}",\n      "rawBeforeSha256": "#{raw}"\n    })
    end
    expected = %({\n  "sourceCommit": "#{@head}",\n  "files": {\n#{files.join(",\n")}\n  }\n})
    assert_equal expected, File.read(File.join(@root, '.reports/linux-gui/source-before.json'))
  end

  def test_snapshot_rejects_unexpected_tracked_changes
    write_file('Cargo.lock', "# drift\n")
    _output, error, status = run_cli('snapshot')
    refute status.success?
    assert_includes error, 'Unexpected tracked changes before building'
  end

  def test_audit_archives_bundle_with_python_compatible_evidence
    prepare_build
    LinuxGuiArtifactEvidence::Audit.new(root: @root, environment: @env, uname: LINUX, gzip_mtime: 1234).run
    product = File.join(@root, '.reports/linux-gui-product')
    assert_equal %w[build-identity.json epub-to-mp3-flutter-linux-x86_64.tar.gz
                    epub-to-mp3-flutter-linux-x86_64.tar.gz.sha256 files.json
                    generated-localizations.patch generated-source-provenance.json], Dir.children(product).sort

    records = JSON.parse(File.read(File.join(product, 'files.json')))
    expected_order = ['.', 'data', 'data/espeak-ng-data', 'data/espeak-ng-data/lang', 'data/espeak-ng-data/lang/roa',
                      'data/espeak-ng-data/lang/roa/pt', 'data/espeak-ng-data/phondata',
                      'data/espeak-ng-data/phonindex', 'data/espeak-ng-data/phontab', 'data/flutter_assets',
                      'data/flutter_assets/a', 'data/flutter_assets/a/b', 'data/flutter_assets/a.txt',
                      'data/flutter_assets/packages', *long_dirs, LONG, 'flutter_app', 'lib', 'lib/libconverter_ffi.so']
    assert_equal expected_order, records.map { |record| record.fetch('path') }
    assert_equal({ 'path' => 'flutter_app', 'type' => 'file', 'mode' => '0o755', 'bytes' => ELF.bytesize,
                   'sha256' => Digest::SHA256.hexdigest(ELF) }, records.find { |r| r['path'] == 'flutter_app' })
    assert_equal({ 'path' => '.', 'type' => 'directory', 'mode' => '0o755' }, records.first)
    assert_match(/\A\[\n  \{\n    "path": "\.",\n    "type": "directory",\n    "mode": "0o755"\n  \},\n/,
                 File.read(File.join(product, 'files.json')))

    provenance = JSON.parse(File.read(File.join(product, 'generated-source-provenance.json')))
    assert_equal %w[sourceCommit files sourceDescription generatedPatch generatedPatchSha256 beforeSnapshotSha256],
                 provenance.keys
    assert_equal %w[headSha256 rawBeforeSha256 rawAfterSha256], provenance['files'].values.first.keys
    assert_includes File.read(File.join(product, 'generated-localizations.patch')), '+generated'

    archive = File.join(product, 'epub-to-mp3-flutter-linux-x86_64.tar.gz')
    digest = Digest::SHA256.file(archive).hexdigest
    assert_equal "#{digest}  epub-to-mp3-flutter-linux-x86_64.tar.gz\n", File.read("#{archive}.sha256")
    assert_gzip_header(File.binread(archive))
    assert_tar_layout(Zlib::GzipReader.open(archive, &:read).b, expected_order)

    identity_text = File.read(File.join(product, 'build-identity.json'))
    identity = JSON.parse(identity_text)
    assert_equal({ 'CARGO_BUILD_JOBS' => 1, 'CMAKE_BUILD_PARALLEL_LEVEL' => 1, 'ORT_PREFER_DYNAMIC_LINK' => 0,
                   'buildCpu' => 3 }, identity['flags'])
    assert_equal [@head, @head, 'workflow_dispatch', '42', '1', 'x86_64', digest],
                 identity.values_at('sourceCommit', 'eventHeadCommit', 'eventName', 'runId', 'runAttempt',
                                    'architecture', 'archiveSha256')
    assert_match(/\Aruby \d/, identity.dig('toolchains', 'ruby'))
    assert_includes identity_text, "\"note\": \"caf\\u00e9 \\ud83d\\ude00\""
    assert_equal ['libconverter_ffi.so', 'libc.so.6'], identity['elfAudit'].first['needed']
    assert_includes identity['elfAudit'].first['resolvedDependencies'], "#{@root}/#{BUNDLE}/lib/libconverter_ffi.so"
    assert_equal '', identity['elfAudit'].last['resolvedDependencies']
    assert_equal [LinuxGuiArtifactEvidence::GENERATED_PATHS.first], identity['trackedChangesAfterBuild']
    assert_equal Digest::SHA256.file(File.join(product, 'files.json')).hexdigest, identity['filesManifestSha256']
    assert_equal [false, false, false, false], identity.values_at('modelsIncluded', 'applicationLaunched',
                                                                  'guiAcceptancePerformed', 'privateBookTestsExecuted')
  end

  def test_audit_rejects_non_linux_host_after_elf_audit
    prepare_build
    audit = LinuxGuiArtifactEvidence::Audit.new(root: @root, environment: @env,
                                                uname: { sysname: 'Darwin', machine: 'x86_64' })
    error = assert_raises(LinuxGuiArtifactEvidence::Error) { audit.run }
    assert_equal 'Unexpected verification host', error.message
  end

  def test_audit_rejects_missing_abi_and_payloads
    prepare_build
    environment = @env.merge('FAKE_NM_OMIT' => 'converter_string_free')
    error = assert_raises(LinuxGuiArtifactEvidence::Error) do
      LinuxGuiArtifactEvidence::Audit.new(root: @root, environment: environment, uname: LINUX).run
    end
    assert_equal 'Missing packaged ABI: converter_string_free', error.message

    FileUtils.rm_rf(File.join(@root, '.reports/linux-gui-product'))
    write_file("#{BUNDLE}/data/voice.ONNX", 'model')
    error = assert_raises(LinuxGuiArtifactEvidence::Error) do
      LinuxGuiArtifactEvidence::Audit.new(root: @root, environment: @env, uname: LINUX).run
    end
    assert_equal 'Unexpected model, book or audio payload: data/voice.ONNX', error.message
  end

  def test_build_cpu_reads_minimum_allowed_cpu
    status = File.join(@root, 'status')
    File.write(status, "Name:\truby\nCpus_allowed:\tff\nCpus_allowed_list:\t4-7,2,9-11\n")
    assert_equal 2, LinuxGuiArtifactEvidence.build_cpu(status)
    File.write(status, "Name:\truby\n")
    error = assert_raises(LinuxGuiArtifactEvidence::Error) { LinuxGuiArtifactEvidence.build_cpu(status) }
    assert_match(/CPU affinity is unavailable/, error.message)
  end

  def test_json_matches_python_indent_two_formatting
    value = { 'a' => [], 'b' => {}, 'c' => [1, true, nil, 1.5, 1e16], 'd' => "x\u007f\n\"\\/é😀" }
    expected = "{\n  \"a\": [],\n  \"b\": {},\n  \"c\": [\n    1,\n    true,\n    null,\n    1.5,\n    1e+16\n  ],\n" \
               "  \"d\": \"x\\u007f\\n\\\"\\\\/\\u00e9\\ud83d\\ude00\"\n}"
    assert_equal expected, PythonJson.dump(value, indent: 2)
  end

  def test_workflow_invokes_ruby_helper_without_python
    text = File.read(WORKFLOW)
    job = YAML.safe_load(text).fetch('jobs').fetch('linux-package')
    assert_equal 'rust,ruby,flutter', job.fetch('env').fetch('MISE_ENABLE_TOOLS')
    refute_match(/python/i, text)
    runs = job.fetch('steps').to_h { |step| [step['name'], step['run'].to_s] }
    { 'Snapshot tracked generated-source provenance before building' => 'snapshot',
      'Build the normal lib/main.dart app once through its guarded task' => 'build-cpu',
      'Audit and archive only the actual normal product bundle' => 'audit' }.each do |name, subcommand|
      assert_includes runs.fetch(name), "mise exec -- ruby scripts/linux_gui_artifact_evidence.rb #{subcommand}"
    end
  end

  private

  def long_dirs
    parts = LONG.split('/')[3..-2]
    parts.each_index.map { |index| (['data/flutter_assets/packages'] + parts[0..index]).join('/') }
  end

  def prepare_build
    assert run_cli('snapshot').last.success?
    write_file('.reports/linux-gui/build-cpu.txt', "3\n")
    { 'flutter_app' => [ELF, 0o755], 'lib/libconverter_ffi.so' => [ELF + 'so'.b, 0o644],
      'data/espeak-ng-data/phontab' => ['t', 0o644], 'data/espeak-ng-data/phondata' => ['d', 0o644],
      'data/espeak-ng-data/phonindex' => ['i', 0o644], 'data/espeak-ng-data/lang/roa/pt' => ['pt', 0o644],
      'data/flutter_assets/a.txt' => ['a', 0o644], 'data/flutter_assets/a/b' => ['b', 0o600],
      LONG => ['x' * 700, 0o644] }.each { |path, (bytes, mode)| write_file("#{BUNDLE}/#{path}", bytes, mode) }
    Dir.glob("#{@root}/#{BUNDLE}/**/").each { |dir| File.chmod(0o755, dir) }
    write_file('target/flutter-Linux-x86_64/release/libconverter_ffi.so', ELF + 'so'.b)
  end

  def assert_gzip_header(bytes)
    assert_equal "\x1f\x8b\x08\x08".b + [1234].pack('V') + "\x02\xff".b, bytes[0, 10]
    assert_equal "epub-to-mp3-flutter-linux-x86_64.tar\0".b, bytes[10, 37]
  end

  def assert_tar_layout(tar, expected_order)
    assert_equal 0, tar.bytesize % 10_240
    members = []
    offset = 0
    pending = nil
    while (block = tar.byteslice(offset, 512)) && block != ("\0" * 512).b
      size = block[124, 12].to_i(8)
      data = tar.byteslice(offset + 512, size)
      offset += 512 + ((size + 511) / 512 * 512)
      assert_equal "ustar\x0000".b, block[257, 8]
      assert_equal block[0, 148].bytes.sum + block[156..].bytes.sum + 256, block[148, 6].to_i(8)
      assert_equal "\0".b * 16, block[329, 16]
      if block[156] == 'x'
        assert_equal '././@PaxHeader', block[0, 100].delete("\0")
        pending = data[/ path=(.*)\n\z/, 1]
        assert_equal data.bytesize, data.to_i
        next
      end
      assert_equal ['0000000', '0000000', '00000000000', '', ''],
                   [block[108, 7], block[116, 7], block[136, 11], block[265, 32].delete("\0"),
                    block[297, 32].delete("\0")]
      name = pending || block[0, 100].delete("\0")
      pending = nil
      members << [name, block[156], block[100, 7].to_i(8), data]
    end
    expected = expected_order.map do |path|
      name = path == '.' ? 'epub-to-mp3-linux' : "epub-to-mp3-linux/#{path}"
      File.directory?(File.join(@root, BUNDLE, path)) ? "#{name}/" : name
    end
    assert_equal expected, members.map(&:first)
    by_name = members.to_h { |name, type, mode, data| [name, [type, mode, data]] }
    assert_equal ['0', 0o755, ELF], by_name.fetch('epub-to-mp3-linux/flutter_app')
    assert_equal ['0', 0o600, 'b'], by_name.fetch('epub-to-mp3-linux/data/flutter_assets/a/b')
    assert_equal ['5', 0o755, ''], by_name.fetch('epub-to-mp3-linux/lib/')
    assert_equal 'x' * 700, by_name.fetch("epub-to-mp3-linux/#{LONG}").last
  end

  def write_file(relative, bytes, mode = 0o644, shebang: false)
    path = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, shebang ? "#!/bin/sh\nset -eu\n#{bytes}" : bytes)
    File.chmod(mode, path)
  end

  def git(*args)
    output, status = Open3.capture2e(@env, 'git', *args, chdir: @root)
    raise "git #{args.join(' ')} failed: #{output}" unless status.success?

    output
  end

  def run_cli(*args)
    Open3.capture3(@env, RbConfig.ruby, SCRIPT, *args, chdir: @root)
  end
end
