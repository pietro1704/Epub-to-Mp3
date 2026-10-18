require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'yaml'
require 'digest'
require 'rbconfig'

class HfSnapshotWorkflowTest < Minitest::Test
  REPOSITORY = File.expand_path('..', __dir__)
  WASM = 'web/src/wasm/converter_wasm_bg.wasm'.freeze

  def setup
    @root = Dir.mktmpdir('hf workflow fixture with spaces ')
    @source = File.join(@root, 'source')
    @home = File.join(@root, 'home')
    @temporary = File.join(@root, 'temporary')
    FileUtils.mkdir_p([@source, @home, @temporary])
    @environment_file = File.join(@root, 'github-env')
    @env = {
      'PATH' => "#{File.dirname(RbConfig.ruby)}:#{ENV.fetch('PATH')}",
      'HOME' => @home, 'TMPDIR' => @temporary, 'RUNNER_TEMP' => @temporary,
      'GITHUB_WORKSPACE' => @source, 'GITHUB_ENV' => @environment_file,
      'GIT_CONFIG_NOSYSTEM' => '1', 'GIT_CONFIG_GLOBAL' => '/dev/null',
      'GIT_ALLOW_PROTOCOL' => 'file', 'GIT_TERMINAL_PROMPT' => '0',
      'GIT_ASKPASS' => '/usr/bin/false',
      'MISE_CONFIG_DIR' => File.join(@home, 'mise-config'),
      'MISE_CACHE_DIR' => File.join(@home, 'mise-cache'),
      'MISE_STATE_DIR' => File.join(@home, 'mise-state'),
      'MISE_DATA_DIR' => File.join(@home, 'mise-data'),
      'MISE_TRUSTED_CONFIG_PATHS' => @source,
      'MISE_INSTALL_MISSING' => 'false', 'MISE_ENABLE_TOOLS' => 'ruby'
    }
    @bytes = "\0asm\x01\0\0\0".b
    {
      'Dockerfile' => 'FROM scratch', 'README.md' => 'Owned workflow fixture',
      'Cargo.toml' => '[workspace]', 'Cargo.lock' => '# Owned fixture',
      'web/package.json' => '{}', WASM => @bytes,
      '.gitattributes' => File.binread(File.join(REPOSITORY, '.gitattributes'))
    }.each { |path, bytes| write(path, bytes) }
    copy_real_snapshot_task
    command!('git', 'init', '--initial-branch=master', chdir: @source)
    command!('git', 'config', 'user.name', 'Workflow fixture', chdir: @source)
    command!('git', 'config', 'user.email', 'fixture@example.invalid', chdir: @source)
    command!('git', 'add', '-A', chdir: @source)
    command!('git', 'commit', '-m', 'Owned fixture', chdir: @source)
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_actual_workflow_generation_stores_wasm_as_lfs_and_restores_its_bytes
    workflow = YAML.safe_load(File.read(File.join(REPOSITORY, '.github/workflows/sync-hf.yml')))
    steps = workflow.fetch('jobs').fetch('sync').fetch('steps').select do |step|
      step.fetch('name', '').start_with?('Build HF-only repo snapshot')
    end
    assert_equal 1, steps.length, 'The real workflow must have one snapshot-generation entrypoint'
    command!('bash', '-euo', 'pipefail', '-c', steps.fetch(0).fetch('run'), chdir: @source)
    assignments = File.readlines(@environment_file, chomp: true).grep(/^HF_SYNC_DIR=/)
    assert_equal 1, assignments.length, 'The generation step must expose its actual snapshot'
    snapshot = File.realpath(assignments.fetch(0).delete_prefix('HF_SYNC_DIR='))
    assert snapshot.start_with?("#{File.realpath(@temporary)}/"), 'Snapshot must stay in the owned temporary root'
    pointer = "version https://git-lfs.github.com/spec/v1\noid sha256:#{Digest::SHA256.hexdigest(@bytes)}\nsize #{@bytes.bytesize}\n"
    assert_equal pointer.b, command!('git', 'show', "HEAD:#{WASM}", chdir: snapshot).b,
                 'The workflow must commit an exact LFS pointer instead of a raw WASM binary'

    remote = File.join(@root, 'remote.git')
    command!('git', 'init', '--bare', '--initial-branch=master', remote, chdir: @root)
    command!('git', 'push', "file://#{remote}", 'HEAD:refs/heads/master', chdir: snapshot)
    assert_equal pointer.b, command!('git', 'show', "master:#{WASM}", chdir: remote).b
    clone = File.join(@root, 'fresh clone')
    command!('git', 'clone', '--no-checkout', "file://#{remote}", clone, chdir: @root)
    command!('git', 'lfs', 'install', '--local', chdir: clone)
    command!('git', 'checkout', 'master', chdir: clone)
    assert_equal @bytes, File.binread(File.join(clone, WASM))
  end

  private

  def copy_real_snapshot_task
    helper = File.join(REPOSITORY, 'scripts/hf_snapshot.rb')
    return unless File.file?(helper)

    # Keep the real task verbatim while excluding unrelated tools and root env.
    sections = File.read(File.join(REPOSITORY, 'mise.toml')).scan(
      /^\[tasks\."hf:snapshot"\]\n.*?(?=^\[|\z)/m
    )
    raise 'Expected exactly one real hf:snapshot task' unless sections.length == 1

    write('mise.toml', sections.fetch(0))
    write('scripts/hf_snapshot.rb', File.binread(helper))
  end

  def command!(*argv, chdir:)
    stdout, stderr, status = Open3.capture3(@env, *argv, chdir: chdir, unsetenv_others: true)
    assert status.success?, "#{argv.first} failed (#{status.exitstatus}): #{stdout}\n#{stderr}"
    stdout
  end

  def write(path, bytes)
    destination = File.join(@source, path)
    FileUtils.mkdir_p(File.dirname(destination))
    File.binwrite(destination, bytes)
  end
end
