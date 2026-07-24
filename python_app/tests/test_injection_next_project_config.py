"""Regression checks for Debug-only InjectionNext integration."""

from pathlib import Path

PROJECT = Path(__file__).resolve().parents[2] / "ios" / "EpubToMp3" / "project.yml"


def test_injection_next_is_linked_only_with_debug_interposition_flags() -> None:
    project = PROJECT.read_text(encoding="utf-8")

    assert "InjectionNext:" in project
    assert "https://github.com/johnno1962/InjectionNext.git" in project
    assert "- package: InjectionNext" in project
    debug_start = project.index("        Debug:")
    release_start = project.index("        Release:", debug_start)
    debug = project[debug_start:release_start]
    release = project[release_start:]
    assert 'OTHER_LDFLAGS: "$(inherited) -Xlinker -interposable"' in debug
    assert "-interposable" not in release
