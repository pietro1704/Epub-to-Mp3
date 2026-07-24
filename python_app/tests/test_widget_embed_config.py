"""Regression guards for the iOS Widget embed wiring.

These tests cover the same invariants `scripts/verify_widget_embedded.sh`
asserts, but run inside the normal pytest CI loop on every push — the
shell script only fires when a developer runs `mise run ios:build` or
`mac:build` locally, which CI does not do for the Apple jobs.

Slices the guards belong to:
  - Slice 18: iOS app target must declare the App→Widget embed dependency.
  - Slice 22: macOS build must exclude EpubToMp3Widget.appex so
    ValidateEmbeddedBinary does not abort with
    "Your target is built for macOS but contains embedded content built
    for the iOS platform".
"""

from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
PROJECT_YML = PROJECT_ROOT / "ios" / "EpubToMp3" / "project.yml"
MISE_TOML = PROJECT_ROOT / "mise.toml"


def test_project_yml_declares_widget_embed_dependency():
    """Slice 18 guard: project.yml must keep the App → EpubToMp3Widget
    `embed: true` dependency so the .appex actually lands inside
    `EpubToMp3.app/PlugIns/`.
    """
    assert PROJECT_YML.is_file(), f"project.yml missing at {PROJECT_YML}"
    body = PROJECT_YML.read_text(encoding="utf-8")

    # Locate the dependency block and verify the embed directive sits
    # within the next few lines (xcodegen's YAML format).
    idx = body.find("target: EpubToMp3Widget")
    assert idx != -1, "project.yml is missing the App → EpubToMp3Widget dependency"
    nearby = body[idx : idx + 200]
    assert "embed: true" in nearby, (
        "project.yml has the EpubToMp3Widget dependency without `embed: true` "
        "— slice 18 regression: the widget will not ship in the .app bundle"
    )


def test_project_yml_excludes_widget_from_macos_build():
    """Slice 22 guard: the macOS build must strip EpubToMp3Widget.appex
    from its embed copy phase, otherwise xcodebuild aborts Release with
    "embedded content built for the iOS platform".
    """
    assert PROJECT_YML.is_file()
    body = PROJECT_YML.read_text(encoding="utf-8")

    # The slice 22 fix added EpubToMp3Widget.appex to the existing per-sdk
    # EXCLUDED_SOURCE_FILE_NAMES exclusion that also strips Python.xcframework
    # from macOS. xcodegen renders this as a single quoted setting.
    macos_excluded_lines = [
        line for line in body.splitlines() if "EXCLUDED_SOURCE_FILE_NAMES[sdk=macosx*]" in line
    ]
    assert macos_excluded_lines, (
        "project.yml is missing EXCLUDED_SOURCE_FILE_NAMES[sdk=macosx*] — "
        "the macOS build will try to embed the iOS-only widget"
    )
    joined = "\n".join(macos_excluded_lines)
    assert "EpubToMp3Widget.appex" in joined, (
        "EXCLUDED_SOURCE_FILE_NAMES[sdk=macosx*] is set but does not include "
        "EpubToMp3Widget.appex — slice 22 regression: macOS Release will fail "
        "ValidateEmbeddedBinary"
    )


def test_widget_has_dedicated_info_plist():
    """Slice 21B guard: the widget target must use its own Info.plist
    file (containing the NSExtension dictionary) so the iOS simulator's
    app-extension placeholder verifier does not abort at install time.
    """
    body = PROJECT_YML.read_text(encoding="utf-8")
    assert "INFOPLIST_FILE: EpubToMp3Widget/Info.plist" in body, (
        "project.yml is no longer pointing the widget target at its "
        "dedicated Info.plist — slice 21B regression: simulator install "
        "fails with 'extensionDictionary must be set in placeholder "
        "attributes for an app extension placeholder'"
    )

    info_plist = PROJECT_ROOT / "ios" / "EpubToMp3" / "EpubToMp3Widget" / "Info.plist"
    assert info_plist.is_file(), f"widget Info.plist missing at {info_plist}"
    plist_body = info_plist.read_text(encoding="utf-8")
    assert "NSExtension" in plist_body, "widget Info.plist is missing the NSExtension dictionary"
    assert "com.apple.widgetkit-extension" in plist_body, (
        "widget Info.plist's NSExtensionPointIdentifier is no longer "
        "set to com.apple.widgetkit-extension"
    )


def test_ios_build_task_does_not_recommend_local_simulator_downloads():
    """Local iOS builds on this Mac must not steer agents toward
    simulator/runtime downloads; use physical-device CLI or CI instead.
    """
    body = MISE_TOML.read_text(encoding="utf-8")
    ios_build_start = body.index('[tasks."ios:build"]')
    next_section = body.index("\n# ──", ios_build_start)
    ios_build_task = body[ios_build_start:next_section]

    assert "xcodebuild -downloadPlatform iOS         #" not in ios_build_task
    assert "Fix on this Mac:\n  xcodebuild -downloadPlatform" not in ios_build_task
    assert "ios:device:run" in ios_build_task
    assert "No local simulator download is required" in ios_build_task


def test_simulator_run_task_requires_an_existing_app_and_never_builds():
    """The explicit simulator launch task must not hide a build step."""
    body = MISE_TOML.read_text(encoding="utf-8")
    start = body.index('[tasks."ios:simulator:run"]')
    end = body.index('\n[tasks."ios:device:test"]', start)
    task = body[start:end]

    assert "guard_ios_simulator_resources.py" in task
    assert "select_ios_simulator.py" in task
    assert "simctl install" in task
    assert "simctl launch" in task
    assert "mise run ios:build" in task
    assert "xcodebuild" not in task
    assert "xcodegen" not in task
    assert "-downloadPlatform" not in task
