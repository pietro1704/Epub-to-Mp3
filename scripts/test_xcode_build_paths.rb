# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require_relative "xcode_build_paths"

class XcodeBuildPathsTest < Minitest::Test
  def test_local_and_hosted_xcode16_names_are_supported_without_global_selection
    assert_equal XcodeBuildPaths::DEVELOPER, XcodeBuildPaths.developer(directory: ->(_) { true })
    assert_equal XcodeBuildPaths::HOSTED_DEVELOPER,
                 XcodeBuildPaths.developer(directory: ->(path) { path == XcodeBuildPaths::HOSTED_DEVELOPER })
    assert_raises(RuntimeError) { XcodeBuildPaths.developer(directory: ->(_) { false }) }
  end

  def make_device_app(cache, configuration: 'Debug', age: 0)
    app = File.join(cache, "Build/Products/#{configuration}-iphoneos/EpubToMp3.app")
    FileUtils.mkdir_p(app)
    File.write(File.join(app, 'identity'), app)
    File.utime(Time.now - age, Time.now - age, app)
    app
  end

  def test_device_launcher_uses_newest_app_from_shared_gui_cache
    cache = File.join(@directory, 'GUI cache')
    make_device_app(cache, configuration: 'Release', age: 3600)
    current = make_device_app(cache)
    FileUtils.mkdir_p(File.join(cache, 'Build/Products/Debug/EpubToMp3.app'))
    assert_equal current, XcodeBuildPaths.device_app(environment: { 'APPLE_DERIVED_DATA_PATH' => cache })
    assert_equal current, XcodeBuildPaths.device_app(environment: {
      'APPLE_DERIVED_DATA_PATH' => cache, 'IOS_DERIVED_DATA_PATH' => ''
    })
  end

  def test_device_launcher_honors_ios_override_and_preserves_both_caches
    shared = File.join(@directory, 'GUI cache')
    separate = File.join(@directory, 'different SDK cache')
    gui_app = make_device_app(shared)
    ios_app = make_device_app(separate, age: 3600)
    before = [gui_app, ios_app].to_h { |app| [app, File.binread(File.join(app, 'identity'))] }
    assert_equal ios_app, XcodeBuildPaths.device_app(environment: {
      'APPLE_DERIVED_DATA_PATH' => shared, 'IOS_DERIVED_DATA_PATH' => separate
    })
    before.each { |app, bytes| assert_equal bytes, File.binread(File.join(app, 'identity')) }
  end

  def test_missing_explicit_ios_app_never_falls_back_to_another_build
    shared = File.join(@directory, 'GUI cache')
    make_device_app(shared)
    error = assert_raises(RuntimeError) do
      XcodeBuildPaths.device_app(environment: {
        'APPLE_DERIVED_DATA_PATH' => shared, 'IOS_DERIVED_DATA_PATH' => File.join(@directory, 'missing')
      })
    end
    assert_match(/No existing iphoneos/, error.message)
  end

  def setup
    @directory = File.realpath(Dir.mktmpdir("shared Xcode cache "))
    @root = File.join(@directory, "checkout")
    @home = File.join(@directory, "home")
    @workspaces = {}
    @reader = ->(path) { [@workspaces.fetch(path), "", Struct.new(:success?).new(true)] }
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def cache(name, workspace: @root, age: 0)
    directory = File.join(@home, "Library/Developer/Xcode/DerivedData", name)
    FileUtils.mkdir_p(directory)
    info = File.join(directory, "info.plist")
    File.write(info, "fixture identity")
    File.utime(Time.now - age, Time.now - age, info)
    @workspaces[info] = File.join(workspace, "ios/EpubToMp3/EpubToMp3.xcodeproj")
    directory
  end

  def resolve(environment = {}, **options)
    XcodeBuildPaths.derived_data(root: @root, home: @home, environment: environment,
                                 reader: @reader, **options)
  end

  def test_reuses_most_recent_gui_workspace_without_touching_older_or_foreign_caches
    old = cache("EpubToMp3-old", age: 3600)
    current = cache("EpubToMp3-current")
    foreign = cache("EpubToMp3-other-worktree", workspace: @root + "-other")
    before = [old, current, foreign].to_h { |path| [path, File.binread(File.join(path, "info.plist"))] }
    assert_equal current, resolve
    before.each { |path, bytes| assert_equal bytes, File.binread(File.join(path, "info.plist")) }
  end

  def test_explicit_isolated_path_is_preserved_without_inspecting_gui_cache
    broken_reader = ->(_) { raise "GUI cache must not be inspected" }
    assert_equal File.join(@root, "separate SDK"), resolve({ "APPLE_DERIVED_DATA_PATH" => "separate SDK" }, reader: broken_reader)
  end

  def test_no_matching_gui_workspace_keeps_one_shared_fallback_without_creating_it
    cache("foreign", workspace: @root + "-other")
    expected = File.join(@root, "ios/EpubToMp3/.build")
    assert_equal expected, resolve
    refute File.exist?(expected)
  end

  def test_unreadable_identity_fails_instead_of_silently_creating_duplicate_cache
    cache("broken")
    failing = ->(_) { ["", "fixture read failure", Struct.new(:success?).new(false)] }
    error = assert_raises(RuntimeError) { resolve({}, reader: failing) }
    assert_match(/Cannot read Xcode cache identity/, error.message)
    refute File.exist?(File.join(@root, "ios/EpubToMp3/.build"))
  end

  def test_cli_rejects_unknown_mode_without_running_a_build
    _, error, status = Open3.capture3(RbConfig.ruby, File.join(__dir__, "xcode_build_paths.rb"), "clean")
    assert_equal 75, status.exitstatus
    assert_match(/Usage:/, error)
  end
end
