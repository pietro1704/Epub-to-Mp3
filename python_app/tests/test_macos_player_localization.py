"""Regression checks for native macOS player localization."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RESOURCES = ROOT / "ios" / "EpubToMp3" / "EpubToMp3" / "Resources"


def test_macos_player_labels_are_defined_for_every_supported_locale() -> None:
    for locale in ("en", "pt-BR", "es"):
        source = (RESOURCES / f"{locale}.lproj" / "Localizable.strings").read_text(encoding="utf-8")
        assert '"player.nothingPlaying"' in source
        assert '"player.fullPlayer"' in source


def test_macos_player_bar_remains_available_for_recently_read_books() -> None:
    root = (
        ROOT / "ios" / "EpubToMp3" / "EpubToMp3" / "App" / "MacAppKitRootController.swift"
    ).read_text(encoding="utf-8")

    assert "private var playerBarHeightConstraint: NSLayoutConstraint?" in root
    assert "let hasReadingContext = player.snapshot != nil" in root
    assert "library.books.contains { $0.lastOpenedAt != nil }" in root
    assert "playerBarHeightConstraint?.constant = hasReadingContext ? 58 : 0" in root
