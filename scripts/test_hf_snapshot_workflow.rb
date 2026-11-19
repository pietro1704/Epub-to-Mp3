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

  def test_actual_rollback_snapshots_only_the_validated_target
    workflow = YAML.safe_load(File.read(File.join(REPOSITORY, '.github/workflows/rollback-hf.yml')))
    steps = workflow.fetch('jobs').fetch('rollback').fetch('steps')
    generation = steps.find { |step| step.fetch('name', '') == 'Build HF-only repo snapshot' }
    assert_equal '${{ steps.validated.outputs.sha }}', generation.fetch('env').fetch('VALIDATED_SHA')
    FileUtils.cp(File.join(REPOSITORY, 'scripts/hf_snapshot.rb'), @temporary)
    write('local-only.txt', 'untracked data')

    @env['VALIDATED_SHA'] = '0' * 40
    _stdout, _stderr, status = Open3.capture3(
      @env, 'bash', '-euo', 'pipefail', '-c', generation.fetch('run'),
      chdir: @source, unsetenv_others: true
    )
    refute status.success?
    refute File.exist?(@environment_file), 'An unvalidated checkout must not prepare a snapshot'

    @env['VALIDATED_SHA'] = command!('git', 'rev-parse', 'HEAD', chdir: @source).strip
    command!('bash', '-euo', 'pipefail', '-c', generation.fetch('run'), chdir: @source)
    snapshot = File.readlines(@environment_file, chomp: true).fetch(0).delete_prefix('HF_SYNC_DIR=')
    assert snapshot.start_with?("#{@temporary}/")
    refute File.exist?(File.join(snapshot, 'local-only.txt'))
    assert_match(/\Aversion https:\/\/git-lfs.github.com\/spec\/v1\n/,
                 command!('git', 'show', "HEAD:#{WASM}", chdir: snapshot))
  end

  # The rollback is the emergency path and also publishes a chosen validated
  # commit. It must publish the way sync-hf does: HTTPS with the token supplied
  # only through GIT_ASKPASS and scripts/hf_push.sh, which lets the Git LFS
  # pre-push hook upload the binaries. A plain `git push` would leave LFS
  # pointers on the Space, and the SSH route fails when hf.co:22 is unreachable.
  def test_rollback_publishes_the_validated_target_through_hf_push_with_the_token_only
    workflow = YAML.safe_load(File.read(File.join(REPOSITORY, '.github/workflows/rollback-hf.yml')))
    steps = workflow.fetch('jobs').fetch('rollback').fetch('steps')
    helper = steps.find { |step| step.fetch('name', '') == 'Snapshot trusted publication helper' }
    assert_includes helper.fetch('run'), 'scripts/hf_push.sh', 'The trusted hf_push.sh must be snapshotted from the default branch'
    push = steps.find { |step| step.fetch('name', '') == 'Push rollback to Hugging Face' }
    refute_nil push
    refute_includes push.fetch('run'), 'ssh', 'The push must not depend on SSH to hf.co'
    refute push.fetch('env').key?('HF_SSH_PRIVATE_KEY')

    bin = File.join(@root, 'fakebin')
    FileUtils.mkdir_p(bin)
    calls = File.join(@root, 'calls.log')
    snapshot = File.join(@temporary, 'hf-rollback.fixture')
    FileUtils.mkdir_p(snapshot)
    File.write(File.join(bin, 'node'), "#!/bin/sh\necho \"node $*\" >> '#{calls}'\n")
    File.write(File.join(@temporary, 'hf_push.sh'), <<~SH)
      #!/bin/bash
      echo "hf_push $1 $2 askpass-user=$("$GIT_ASKPASS" 'Username for x') askpass-secret=$("$GIT_ASKPASS" 'Password for x') prompt=$GIT_TERMINAL_PROMPT" >> '#{calls}'
    SH
    FileUtils.chmod(0o755, [File.join(bin, 'node'), File.join(@temporary, 'hf_push.sh')])
    env = @env.merge('PATH' => "#{bin}:#{@env.fetch('PATH')}", 'HF_SYNC_DIR' => snapshot, 'GITHUB_REPOSITORY' => 'owner/repo',
                     'VALIDATED_SHA' => 'a' * 40, 'HF_TOKEN' => 'fixture-token')

    _out, err, status = Open3.capture3(env, 'bash', '-euo', 'pipefail', '-c', push.fetch('run'), chdir: @root, unsetenv_others: true)
    assert status.success?, err
    log = File.readlines(calls, chomp: true)
    assert_match(%r{\Anode .*validated_merge\.mjs --repo owner/repo --ref #{'a' * 40}\z}, log.fetch(0))
    refute_includes log.fetch(0), '--latest', 'Publishing a chosen validated commit must not require it to be the latest'
    assert_equal "hf_push #{snapshot} https://huggingface.co/spaces/pi1704/epub-to-mp3 askpass-user=user askpass-secret=fixture-token prompt=0",
                 log.fetch(1)
    refute_includes File.read(calls), 'ssh'

    FileUtils.rm_f(calls)
    _out, err, status = Open3.capture3(env.merge('HF_TOKEN' => ''), 'bash', '-euo', 'pipefail', '-c', push.fetch('run'),
                                       chdir: @root, unsetenv_others: true)
    refute status.success?, 'Without a token the push must fail'
    refute File.exist?(calls), "Nothing may be validated or published without a token:\n#{err}"
  end

  REGRESSION_WORKFLOW = '.github/workflows/hf-snapshot-regression.yml'.freeze

  def test_regression_requires_the_rails_layout
    step = regression_step('Select the runtime layout')
    refute layout_step_succeeds?(step), 'no marker selects React, which is not deployable'

    write('.hf-runtime', "rails\n")
    refute layout_step_succeeds?(step), 'an untracked marker must not select a layout'
    command!('git', 'add', '.hf-runtime', chdir: @source)
    assert_equal 'rails', selected_layout(step)

    write('.hf-runtime', "other\n")
    command!('git', 'add', '.hf-runtime', chdir: @source)
    refute layout_step_succeeds?(step), 'an unknown tracked layout must fail the workflow'
  end

  def test_regression_verifies_the_rails_image_with_the_snapshots_own_regression
    steps = regression_steps
    verification = steps.select { |step| step['name'] == 'Verify the Rails image with the regression shipped in the snapshot' }
    assert_equal 1, verification.length
    run = verification.fetch(0).fetch('run')
    # The Rails image is checked by the regression that ships inside the very
    # snapshot that would be deployed, against the image built from it.
    assert_includes run, 'IMAGE=hf-snapshot-regression'
    assert_includes run, '$HF_REGRESSION_ROOT/reconstructed/ruby_app/rails_gateway/bin/image-regression'
    steps.each do |step|
      script = step['run'].to_s
      %w[/api/contract /app/web/dist web/src web/public].each do |removed|
        refute_includes script, removed, "#{step['name']} still expects the React client"
      end
      assert_nil step['if'] && step['if'][/HF_LAYOUT/], "#{step['name']} must not branch on the layout"
    end
    reconstruct = regression_step('Reconstruct the actual snapshot through local LFS transport').fetch('run')
    refute_includes reconstruct, 'case "$HF_LAYOUT"'
    assert_includes reconstruct, 'ruby_app/rails_gateway/browser_runtime/workers/piper_worker.js'
  end

  def test_regression_scripts_are_valid_bash
    regression_steps.each do |step|
      next unless step['run']

      output, status = Open3.capture2e('bash', '-n', stdin_data: step.fetch('run'))
      assert status.success?, "#{step['name']} is not valid bash: #{output}"
    end
  end

  private

  def regression_steps
    YAML.safe_load(File.read(File.join(REPOSITORY, REGRESSION_WORKFLOW))).fetch('jobs').fetch('snapshot').fetch('steps')
  end

  def regression_step(name)
    matches = regression_steps.select { |step| step['name'] == name }
    assert_equal 1, matches.length, "Expected exactly one regression step named #{name}"
    matches.fetch(0)
  end

  def selected_layout(step)
    File.write(@environment_file, '')
    command!('bash', '-euo', 'pipefail', '-c', step.fetch('run'), chdir: @source)
    assignments = File.readlines(@environment_file, chomp: true).grep(/^HF_LAYOUT=/)
    assert_equal 1, assignments.length, 'The step must export exactly one layout'
    assignments.fetch(0).delete_prefix('HF_LAYOUT=')
  end

  def layout_step_succeeds?(step)
    _, status = Open3.capture2e(@env, 'bash', '-euo', 'pipefail', '-c', step.fetch('run'), chdir: @source, unsetenv_others: true)
    status.success?
  end

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
