# frozen_string_literal: true

require "minitest/autorun"

# Regression guards for the iOS Widget embed wiring. They cover the invariants
# scripts/verify_widget_embedded.sh asserts, but run in the host contract CI
# loop on every push, because that shell script only fires on local Apple builds.
#   Slice 18: the iOS app target declares the App -> Widget embed dependency.
#   Slice 22: the macOS build excludes EpubToMp3Widget.appex so
#   ValidateEmbeddedBinary does not abort on iOS-only embedded content.
class WidgetEmbedConfigTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PROJECT_YML = File.join(ROOT, "ios/EpubToMp3/project.yml")
  MISE_TOML = File.join(ROOT, "mise.toml")

  def project
    assert File.file?(PROJECT_YML), "project.yml missing at #{PROJECT_YML}"
    File.read(PROJECT_YML)
  end

  def nearby(body, needle, length)
    index = body.index(needle)
    refute_nil index, "project.yml is missing #{needle}"
    body[index, length]
  end

  def test_project_yml_declares_widget_embed_dependency
    assert_includes nearby(project, "target: EpubToMp3Widget", 200), "embed: true",
                    "the EpubToMp3Widget dependency lacks `embed: true`: the widget will not ship in the .app bundle"
  end

  def test_project_yml_excludes_widget_from_macos_build
    lines = project.lines.grep(/EXCLUDED_SOURCE_FILE_NAMES\[sdk=macosx\*\]/)
    refute_empty lines, "EXCLUDED_SOURCE_FILE_NAMES[sdk=macosx*] is missing: macOS would embed the iOS-only widget"
    assert_includes lines.join, "EpubToMp3Widget.appex",
                    "the macOS exclusion does not include EpubToMp3Widget.appex: Release fails ValidateEmbeddedBinary"
  end

  def test_ios_only_extensions_have_ios_platform_filters
    body = project
    %w[EpubToMp3Widget EpubToMp3ShareExtension].each do |target|
      assert_includes nearby(body, "target: #{target}", 180), "destinationFilters: [iOS]",
                      "#{target} embed dependency is missing destinationFilters: [iOS]"
    end
  end

  def test_widget_has_dedicated_info_plist
    assert_includes project, "INFOPLIST_FILE: EpubToMp3Widget/Info.plist",
                    "the widget target no longer uses its dedicated Info.plist (slice 21B)"
    info_plist = File.join(ROOT, "ios/EpubToMp3/EpubToMp3Widget/Info.plist")
    assert File.file?(info_plist), "widget Info.plist missing at #{info_plist}"
    plist = File.read(info_plist)
    assert_includes plist, "NSExtension"
    assert_includes plist, "com.apple.widgetkit-extension"
  end

  # Local iOS builds must not steer agents toward simulator/runtime downloads.
  def test_ios_build_task_does_not_recommend_local_simulator_downloads
    body = File.read(MISE_TOML)
    start = body.index('[tasks."ios:build"]') or flunk("ios:build task is missing")
    finish = body.index("\n# ──", start) or flunk("section separator after ios:build is missing")
    task = body[start...finish]

    refute_includes task, "xcodebuild -downloadPlatform iOS         #"
    refute_includes task, "Fix on this Mac:\n  xcodebuild -downloadPlatform"
    assert_includes task, "ios:device:run"
    assert_includes task, "No local simulator download is required"
  end

  def test_simulator_run_task_requires_an_existing_app_and_never_builds
    body = File.read(MISE_TOML)
    start = body.index('[tasks."ios:simulator:run"]') or flunk("ios:simulator:run task is missing")
    finish = body.index("\n[tasks.\"ios:simulator:test\"]", start) or flunk("ios:simulator:test task is missing")
    task = body[start...finish]

    assert_includes task, "native_job.rb\" simulator"
    assert_includes task, "select_ios_simulator.rb"
    assert_includes task, "simctl install"
    assert_includes task, "simctl launch"
    assert_includes task, "mise run ios:build"
    refute_includes task, "xcodebuild"
    refute_includes task, "xcodegen"
    refute_includes task, "-downloadPlatform"
    refute_includes task, "python"
  end
end
