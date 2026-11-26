# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'

# The root Cargo.toml workspace version is the product version (D22). These
# checks read the real manifests and run the real bump script in a scratch Git
# repository; they never touch this checkout's history.
class VersionSourceTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  VERSION = /^\[workspace\.package\][^\[]*?^version = "([^"]+)"/m

  def workspace_version(root = ROOT)
    File.read(File.join(root, 'Cargo.toml'))[VERSION, 1]
  end

  def test_gateway_version_file_mirrors_the_workspace_version
    gateway = File.read(File.join(ROOT, 'ruby_app/rails_gateway/VERSION')).strip
    assert_match(/\A\d+\.\d+\.\d+\z/, workspace_version)
    assert_equal workspace_version, gateway
  end

  # Local Xcode builds read project.yml directly; only the release workflow
  # overrides MARKETING_VERSION from the tag.
  def apple_marketing_version(root = ROOT)
    File.read(File.join(root, 'ios/EpubToMp3/project.yml'))[/^\s*MARKETING_VERSION: "([^"]+)"$/, 1]
  end

  def flutter_version(root = ROOT)
    File.read(File.join(root, 'flutter_app/pubspec.yaml'))[/^version: (\S+)$/, 1]
  end

  def test_apple_marketing_version_mirrors_the_workspace_version
    assert_equal workspace_version, apple_marketing_version
  end

  def test_flutter_version_name_mirrors_the_workspace_version
    assert_match(/\A\d+\.\d+\.\d+\+\d+\z/, flutter_version)
    assert_equal workspace_version, flutter_version.split('+').first
  end

  def test_version_source_no_longer_includes_the_removed_react_package
    refute File.exist?(File.join(ROOT, 'web/package.json'))
    refute_includes File.read(File.join(ROOT, 'scripts/bump.sh')), 'web/package.json'
  end

  def test_release_workflow_reads_the_workspace_version
    workflow = File.read(File.join(ROOT, '.github/workflows/auto-release.yml'))
    assert_includes workflow, 'product_version = cargo[/^\[workspace\.package\][^\[]*?^version = "([^"]+)"/m, 1]'
    refute_match(/\bpython3?\b/, workflow)
    refute_includes workflow, 'version.py'
  end

  def test_bump_updates_cargo_lock_members_and_gateway_version
    Dir.mktmpdir('version bump ') do |directory|
      %w[Cargo.toml Cargo.lock ruby_app/rails_gateway/VERSION ios/EpubToMp3/project.yml flutter_app/pubspec.yaml
         scripts/bump.sh].each do |path|
        FileUtils.mkdir_p(File.join(directory, File.dirname(path)))
        FileUtils.cp(File.join(ROOT, path), File.join(directory, path))
      end
      Dir.chdir(ROOT) { Dir['{crates,benches,native}/**/Cargo.toml'] }.each do |path|
        next if path.include?('/vendor/') && !File.read(File.join(ROOT, path)).include?('version.workspace')

        FileUtils.mkdir_p(File.join(directory, File.dirname(path)))
        FileUtils.cp(File.join(ROOT, path), File.join(directory, path))
      end
      File.write(File.join(directory, 'CHANGELOG.md'), "# Changelog\n")
      git = ->(*args) { Open3.capture3('git', '-C', directory, '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false', '-c', 'tag.gpgsign=false', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', *args) }
      git.call('init', '-q')
      git.call('add', '-A')
      git.call('commit', '-q', '-m', 'fixture')
      before = File.read(File.join(directory, 'Cargo.lock'))
      current = workspace_version(directory)
      build_number = flutter_version(directory).split('+').last
      environment = { 'PATH' => "#{File.dirname(RbConfig.ruby)}:/usr/bin:/bin", 'GIT_CONFIG_GLOBAL' => '/dev/null',
                      'GIT_AUTHOR_NAME' => 'Fixture', 'GIT_AUTHOR_EMAIL' => 'fixture@example.invalid',
                      'GIT_COMMITTER_NAME' => 'Fixture', 'GIT_COMMITTER_EMAIL' => 'fixture@example.invalid' }
      output, error, status = Open3.capture3(environment, 'bash', File.join(directory, 'scripts/bump.sh'), '9.8.7', chdir: directory)
      assert status.success?, "#{output}#{error}"
      assert_equal '9.8.7', workspace_version(directory)
      assert_equal "9.8.7\n", File.read(File.join(directory, 'ruby_app/rails_gateway/VERSION'))
      assert_equal '9.8.7', apple_marketing_version(directory)
      assert_equal "9.8.7+#{build_number}", flutter_version(directory), 'the Flutter build number is kept'
      committed, = git.call('show', '--name-only', '--format=', 'HEAD')
      assert_includes committed, 'ios/EpubToMp3/project.yml'
      assert_includes committed, 'flutter_app/pubspec.yaml'
      lock = File.read(File.join(directory, 'Cargo.lock'))
      %w[converter-core converter-ffi converter-server converter-cli converter-wasm rust-migration-bench].each do |name|
        assert_includes lock, %(name = "#{name}"\nversion = "9.8.7"\n), name
      end
      changed = lock.lines - before.lines
      assert_equal 6, changed.count { |line| line.start_with?('version = ') }, "only workspace members change (was #{current})"
      tags, = git.call('tag', '--list')
      assert_equal "v9.8.7\n", tags
    end
  end
end
