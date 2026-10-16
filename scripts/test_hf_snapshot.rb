require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'
require_relative 'hf_snapshot'

class HfSnapshotTest < Minitest::Test
  SCRIPT = File.expand_path('hf_push.sh', __dir__)
  CLEAN_GIT = { 'GIT_CONFIG_NOSYSTEM' => '1', 'GIT_CONFIG_GLOBAL' => File::NULL,
                'GIT_LFS_SKIP_SMUDGE' => nil, 'GIT_LFS_SKIP_PUSH' => nil }.freeze

  def setup
    @directory = Dir.mktmpdir('hf snapshot ')
    @source = File.join(@directory, 'source tree')
    @snapshot = File.join(@directory, 'snapshot tree')
    @remote = File.join(@directory, 'remote.git')
    FileUtils.mkdir_p(@source)
    git!('init', '--initial-branch=master', chdir: @source)
    git!('config', 'user.name', 'fixture', chdir: @source)
    git!('config', 'user.email', 'fixture@example.invalid', chdir: @source)
    @inputs = {
      'Dockerfile' => 'FROM scratch', 'README.md' => 'fixture',
      'Cargo.toml' => '[workspace]', 'Cargo.lock' => '# fixture',
      'web/package.json' => '{}', 'web/src/wasm/converter_wasm_bg.wasm' => "\0asm\x01\0\0\0".b,
      'web/public/sample.epub' => "PK\x03\x04\0epub".b,
      'web/public/image with spaces.png' => "\x89PNG\0image".b,
      'native/vendor/espeak-rs-sys/espeak-ng/phsource/a.wav' => "RIFF\0WAVE".b,
      'native/vendor/piper-rs/Cargo.toml' => '[package]',
      'native/piper-runtime/Cargo.toml' => '[package]', 'benches/Cargo.toml' => '[package]'
    }
    @inputs.each { |path, bytes| write(path, bytes) }
    write('.env', 'must-not-upload')
    write('ios/private.txt', 'must-not-upload')
    write('pretrained_models/private.onnx', "\0weights")
    write('docs/private.txt', 'must-not-upload')
    git!('add', '-A', chdir: @source)
    git!('commit', '-m', 'fixture', chdir: @source)
    git!('init', '--bare', '--initial-branch=master', @remote, chdir: @directory)
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_real_lfs_transport_restores_all_binary_bytes_and_excludes_root_data
    snapshot!
    output, status = push
    assert status.success?, output
    # Inspect the remote Git object, independently of the source working tree.
    pointer = git!('show', 'master:web/src/wasm/converter_wasm_bg.wasm', chdir: @remote)
    assert_match(/\Aversion https:\/\/git-lfs.github.com\/spec\/v1\n/, pointer)
    clone = File.join(@directory, 'fresh clone')
    git!('clone', "file://#{@remote}", clone, chdir: @directory)
    @inputs.each { |path, bytes| assert_equal bytes, File.binread(File.join(clone, path)), path }
    %w[.env ios pretrained_models docs].each { |path| refute File.exist?(File.join(clone, path)), path }
    assert_equal git!('rev-parse', 'master', chdir: @remote), git!('rev-parse', 'main', chdir: @remote)
    refute_includes File.read(File.join(@snapshot, '.git/config')), 'HF_TOKEN'
  end

  def test_rejected_primary_push_propagates_failure
    snapshot!
    reject_push('all')
    output, status = push
    refute status.success?, output
    refute_includes output, 'completed successfully'
    _, master = capture('git', 'rev-parse', '--verify', 'master', chdir: @remote)
    refute master.success?
  end

  def test_rejected_secondary_push_is_not_silently_successful
    snapshot!
    reject_push('main')
    output, status = push
    refute status.success?, output
    refute_includes output, 'completed successfully'
    git!('rev-parse', '--verify', 'master', chdir: @remote)
    _, main = capture('git', 'rev-parse', '--verify', 'main', chdir: @remote)
    refute main.success?
  end

  def test_missing_lfs_input_cannot_be_uploaded_as_a_pointer
    write('web/src/wasm/converter_wasm_bg.wasm', "version https://git-lfs.github.com/spec/v1\noid sha256:#{'a' * 64}\nsize 8\n")
    error = assert_raises(RuntimeError) { snapshot! }
    assert_includes error.message, 'Unresolved LFS pointer'
  end

  def test_missing_wasm_and_nonempty_destination_fail_before_git_commit
    git!('rm', 'web/src/wasm/converter_wasm_bg.wasm', chdir: @source)
    assert_raises(RuntimeError) { snapshot! }
    FileUtils.mkdir_p(@snapshot)
    sentinel = File.join(@snapshot, 'keep')
    File.write(sentinel, 'owned elsewhere')
    assert_raises(RuntimeError) { snapshot! }
    assert_equal 'owned elsewhere', File.read(sentinel)
  end

  private

  def snapshot!
    # Exercise the real entrypoint with clean Git configuration and actual git-lfs.
    output, status = capture(RbConfig.ruby, File.expand_path('hf_snapshot.rb', __dir__), @source, @snapshot, chdir: @directory)
    raise output unless status.success?
    output
  end

  def push
    capture('bash', SCRIPT, @snapshot, "file://#{@remote}", chdir: @directory)
  end

  def reject_push(mode)
    path = File.join(@remote, 'hooks/pre-receive')
    File.write(path, "#!/bin/sh\nwhile read old new ref; do\n  if [ '#{mode}' = all ] || [ \"$ref\" = refs/heads/main ]; then exit 41; fi\ndone\n")
    File.chmod(0o755, path)
  end

  def capture(*argv, chdir:)
    Open3.capture2e(CLEAN_GIT, *argv, chdir: chdir)
  end

  def git!(*argv, chdir:)
    output, status = capture('git', *argv, chdir: chdir)
    raise output unless status.success?
    output
  end

  def write(path, bytes)
    target = File.join(@source, path)
    FileUtils.mkdir_p(File.dirname(target))
    File.binwrite(target, bytes)
  end
end
