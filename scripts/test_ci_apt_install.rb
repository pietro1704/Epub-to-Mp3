# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'yaml'

class CiAptInstallTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  SCRIPT = File.join(ROOT, 'scripts/ci_apt_install.sh')
  CALLERS = {
    'ci.yml' => 'espeak-ng-data', 'cli-faber-golden.yml' => 'ffmpeg', 'faber-integration.yml' => 'clang',
    'linux-gui-artifact.yml' => 'libgtk-3-dev', 'native-fallback.yml' => 'espeak-ng ffmpeg',
    'flutter-rust-faber.yml' => 'ffmpeg', 'codeql.yml' => 'clang libclang-dev'
  }.freeze

  def setup
    @dir = Dir.mktmpdir('apt-fixture')
    @log = File.join(@dir, 'log')
    @bin = File.join(@dir, 'bin')
    FileUtils.mkdir_p(@bin)
    shim('sudo', 'echo "sudo $*" >> "$LOG"; case "$*" in *normalize_ubuntu*) exit 0;; esac; exec "$@"')
    shim('apt-get', 'echo "apt-get $*" >> "$LOG"; case "$*" in *install*) n=$(cat "$COUNT" 2>/dev/null || echo 0); echo $((n+1)) > "$COUNT"; [ "$n" -lt "${FAIL_INSTALLS:-0}" ] && exit 100;; esac; exit 0')
    shim('timeout', 'echo "timeout $1" >> "$LOG"; shift; exec "$@"')
    shim('dpkg', 'for last; do :; done; case " $INSTALLED " in *" $last "*) exit 0;; esac; exit 1')
  end

  def teardown = FileUtils.remove_entry(@dir)

  def shim(name, body)
    path = File.join(@bin, name)
    File.write(path, "#!/bin/bash\n#{body}\n")
    FileUtils.chmod(0o755, path)
  end

  def run_script(*args, **env)
    Open3.capture3({ 'PATH' => "#{@bin}:#{ENV.fetch('PATH')}", 'LOG' => @log, 'COUNT' => File.join(@dir, 'count'),
                     'CI_APT_RETRY_DELAY' => '0' }.merge(env.transform_keys(&:to_s)), 'bash', SCRIPT, *args)
  end

  def log = File.exist?(@log) ? File.read(@log) : ''

  def test_installs_only_missing_packages_with_the_hard_limit_and_validation_intact
    out, err, status = run_script('clang', 'cmake', INSTALLED: 'clang')
    assert status.success?, "#{out}#{err}"
    assert_includes log, 'timeout 150'
    assert_includes log, 'install -y --no-install-recommends cmake'
    refute_includes log, 'install -y --no-install-recommends clang'
    assert_includes log, 'APT::Update::Error-Mode=any'
    assert_includes log, 'normalize_ubuntu_package_mirror.rb'
    refute_match(/allow-unauthenticated|allow-insecure|trusted=yes/, log)
  end

  def test_skips_apt_entirely_when_everything_is_installed
    out, err, status = run_script('clang', INSTALLED: 'clang')
    assert status.success?, "#{out}#{err}"
    refute_includes log, 'apt-get'
  end

  def test_retries_up_to_three_attempts_then_succeeds
    _out, _err, status = run_script('cmake', FAIL_INSTALLS: '2')
    assert status.success?
    assert_equal 3, log.scan(/^apt-get .* install -y/).size
  end

  def test_fails_after_three_attempts
    _out, err, status = run_script('cmake', FAIL_INSTALLS: '9')
    refute status.success?
    assert_equal 3, log.scan(/^apt-get .* install -y/).size
    assert_includes err, 'failed after 3 attempts'
  end

  def test_recommends_flag_and_timeout_override
    _out, _err, status = run_script('--install-recommends', 'cmake', CI_APT_ATTEMPT_TIMEOUT: '240')
    assert status.success?
    assert_includes log, 'timeout 240'
    refute_includes log, '--no-install-recommends'
  end

  def test_archive_directory_is_opt_in_and_keeps_validation_intact
    run_script('cmake')
    refute_includes log, 'Dir::Cache::Archives'
    archives = File.join(@dir, 'debs')
    out, err, status = run_script('cmake', CI_APT_ARCHIVES: archives)
    assert status.success?, "#{out}#{err}"
    assert_includes log, "Dir::Cache::Archives=#{archives}"
    assert_includes log, 'APT::Keep-Downloaded-Packages=true'
    assert File.directory?(File.join(archives, 'partial'))
    assert_equal 2, log.lines.grep(/^apt-get .*Dir::Cache::Archives=#{Regexp.escape(archives)}/).size, 'update and install share the archive'
    refute_match(/allow-unauthenticated|allow-insecure|trusted=yes/, log)
  end

  def test_every_heavy_apt_site_caches_its_debs_under_a_keyed_archive
    CALLERS.each do |file, packages|
      workflow = YAML.load_file(File.join(ROOT, '.github/workflows', file))
      steps = workflow.fetch('jobs').values.flat_map { |job| job.fetch('steps', []) }
      index = steps.index { |entry| entry['run'].to_s.include?('scripts/ci_apt_install.sh') && packages.split.all? { |p| entry['run'].include?(p) } }
      assert_equal '${{ runner.temp }}/apt-archives', steps[index].dig('env', 'CI_APT_ARCHIVES'), file
      cache = steps[index - 1]
      assert_match(%r{\Aactions/cache(/restore)?@[0-9a-f]{40}\b}, cache['uses'].to_s, file)
      assert_equal '${{ runner.temp }}/apt-archives', cache.dig('with', 'path'), file
      assert_includes cache.dig('with', 'key'), 'steps.apt-image.outputs.image', file
    end
  end

  def test_cli_bound_covers_a_cold_slow_download_in_one_attempt
    workflow = YAML.load_file(File.join(ROOT, '.github/workflows/cli-faber-golden.yml'))
    step = workflow.fetch('jobs').fetch('packaged-cli').fetch('steps').find { |s| s['name'].to_s.start_with?('Install native build and full audio') }
    attempts = Integer(step.dig('env', 'CI_APT_ATTEMPTS'))
    limit = Integer(step.dig('env', 'CI_APT_ATTEMPT_TIMEOUT'))
    assert_operator limit, :>=, 540
    assert_operator attempts * limit + 60, :<=, step.fetch('timeout-minutes') * 60
  end

  def test_every_apt_site_uses_the_script_with_a_step_bound
    CALLERS.each do |file, packages|
      text = File.read(File.join(ROOT, '.github/workflows', file))
      refute_includes text, 'sudo apt-get', file
      refute_includes text, 'apt_options', file
      workflow = YAML.load_file(File.join(ROOT, '.github/workflows', file))
      steps = workflow.fetch('jobs').values.flat_map { |job| job.fetch('steps', []) }
      step = steps.find { |entry| entry['run'].to_s.include?('scripts/ci_apt_install.sh') && packages.split.all? { |p| entry['run'].include?(p) } }
      refute_nil step, file
      assert_operator step.fetch('timeout-minutes'), :>=, 8, file
    end
  end
end
