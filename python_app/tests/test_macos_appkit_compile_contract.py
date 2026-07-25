"""Prevent macOS AppKit compile regressions caught by release CI."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2] / "ios" / "EpubToMp3" / "EpubToMp3"


def _source(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


def test_appkit_controllers_do_not_use_uikit_only_apis() -> None:
    root = _source("App/MacAppKitRootController.swift")
    reader = _source("Features/Reader/Views/MacReaderViewController.swift")

    assert "didMove(toParent:" not in root
    assert ".stretch" not in root
    assert "dividerStyle" not in reader
    assert ".stretch" not in reader


def test_mac_reader_uses_ebook_chapter_name_and_explicit_async_parse() -> None:
    reader = _source("Features/Reader/Views/MacReaderViewController.swift")

    assert 'chapter.name ?? ""' in reader
    assert "cachedPayload = LocalFulltextCache.read" in reader
    assert "try await MacEpubParser.parse" in reader
    assert "?? try await" not in reader


def test_mac_epub_parser_uses_the_embedded_python_bridge() -> None:
    parser = _source("Features/Documents/Services/MacEpubParser.swift")

    assert "PythonBridge.shared.parseEpub" in parser
    assert "Process()" not in parser
