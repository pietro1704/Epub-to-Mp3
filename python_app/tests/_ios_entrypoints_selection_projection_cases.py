"""Selection Projection regression scenarios, collected by test_ios_entrypoints."""

from __future__ import annotations

import python_app.tests._ios_entrypoints_test_support as _shared_test_exports
from python_app.tests._ios_entrypoints_test_support import FIXTURE_EPUB as FIXTURE_EPUB
from python_app.tests._ios_entrypoints_test_support import Path as Path
from python_app.tests._ios_entrypoints_test_support import ios_entrypoints as ios_entrypoints
from python_app.tests._ios_entrypoints_test_support import pytest as pytest

_fake_transport = _shared_test_exports._fake_transport
os = _shared_test_exports.os


# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------


def test_convert_epub_with_fixture(tmp_path: Path, _fake_transport):
    """End-to-end happy path: real EPUB, fake transport. Manifest, output
    files, and applied_options must all be populated; no errors.
    """
    if not FIXTURE_EPUB.exists():
        pytest.skip("fixture EPUB missing")

    out_root = tmp_path / "out"
    cache_root = tmp_path / "cache"

    result = ios_entrypoints.convert_epub(
        epub_path=str(FIXTURE_EPUB),
        output_dir=str(out_root),
        cache_dir=str(cache_root),
        voice="en-US-AriaNeural",
    )

    assert result["errors"] == [], f"unexpected errors: {result['errors']}"
    assert result["outputs"], "no MP3 outputs produced"
    assert result["book_title"], "book_title missing"
    assert result["manifest"], "manifest empty"

    # Every successful manifest entry must have output_path + status.
    completed = [m for m in result["manifest"] if m.get("status") == "completed"]
    assert completed, "no completed chapters"
    for entry in completed:
        assert "output_path" in entry
        assert Path(entry["output_path"]).exists(), entry["output_path"]
        assert entry["voice"] == "en-US-AriaNeural"

    # Outputs land under output_dir/<sanitized book title>/.
    for path in result["outputs"]:
        assert Path(path).is_file()
        assert Path(path).stat().st_size > 0
        assert str(out_root) in path

    # applied_options snapshot should include every CLI key passed in.
    applied = result["applied_options"]
    assert applied["engine"] == "edge"
    assert applied["voice"] == "en-US-AriaNeural"
    assert applied["fallback_engine"] == "none"

    # The fake transport must have been invoked at least once per
    # completed chapter (chunking may produce more than one call).
    assert len(_fake_transport) >= len(completed)
    for _text, voice_id in _fake_transport:
        assert voice_id == "en-US-AriaNeural"


# ---------------------------------------------------------------------------
# Cache dir routing
# ---------------------------------------------------------------------------


def test_convert_epub_respects_cache_dir(tmp_path: Path, _fake_transport):
    """A custom ``cache_dir`` must be applied: outputs land under
    ``output_dir``, cache artefacts (telemetry, etc.) under ``cache_dir``,
    and the returned ``cache_dir`` matches.
    """
    if not FIXTURE_EPUB.exists():
        pytest.skip("fixture EPUB missing")

    out_root = tmp_path / "ios_output"
    cache_root = tmp_path / "ios_cache"

    result = ios_entrypoints.convert_epub(
        epub_path=str(FIXTURE_EPUB),
        output_dir=str(out_root),
        cache_dir=str(cache_root),
        chapter=1,
    )

    assert result["cache_dir"] == str(cache_root)
    assert str(out_root) in result["output_dir"]
    # Successful outputs all live inside out_root.
    for path in result["outputs"]:
        assert path.startswith(str(out_root)), path
    # cache_root must have been materialised on disk.
    assert cache_root.exists()


def test_convert_epub_override_max_chapter_chars(tmp_path: Path, _fake_transport):
    """``max_chapter_chars`` skips oversized chapters and surfaces them
    in ``errors`` so the UI can warn the user. The value is also exported
    to ``MAX_CHAPTER_CHARS`` for downstream tools.
    """
    if not FIXTURE_EPUB.exists():
        pytest.skip("fixture EPUB missing")
    import os

    # A tiny cap forces every chapter to be flagged as oversized.
    result = ios_entrypoints.convert_epub(
        epub_path=str(FIXTURE_EPUB),
        output_dir=str(tmp_path / "out"),
        cache_dir=str(tmp_path / "cache"),
        max_chapter_chars=1,
    )

    assert os.environ.get("MAX_CHAPTER_CHARS") == "1"
    assert result["errors"], "expected oversize errors"
    skipped = [m for m in result["manifest"] if m.get("status") == "skipped"]
    assert skipped, "expected at least one skipped chapter"
    assert any("exceeds max_chapter_chars" in (m.get("reason") or "") for m in skipped)


# ---------------------------------------------------------------------------
# Chapter filter
# ---------------------------------------------------------------------------


def test_convert_epub_chapter_filter(tmp_path: Path, _fake_transport):
    """``chapter=1`` must restrict synthesis to chapter 1 (and its dotted
    subchapters if any). Other chapters do not appear in manifest.
    """
    if not FIXTURE_EPUB.exists():
        pytest.skip("fixture EPUB missing")

    # Discover the available chapter indices first via show_structure so
    # we don't hard-code knowledge about the fixture's TOC.
    structure = ios_entrypoints.convert_epub(
        epub_path=str(FIXTURE_EPUB),
        output_dir=str(tmp_path / "discover_out"),
        cache_dir=str(tmp_path / "discover_cache"),
        show_structure=True,
    )
    indices = [str(m["index"]) for m in structure["manifest"]]
    assert indices, "fixture should expose chapters"
    target = indices[0]

    result = ios_entrypoints.convert_epub(
        epub_path=str(FIXTURE_EPUB),
        output_dir=str(tmp_path / "out"),
        cache_dir=str(tmp_path / "cache"),
        chapter=target,
    )
    seen_indices = {m["index"] for m in result["manifest"]}
    # Every manifest entry must match the selector. Dotted children of
    # ``target`` (e.g. "1.1") are allowed under CLI semantics.
    for idx in seen_indices:
        assert idx == target or idx.startswith(f"{target}."), idx


def test_convert_epub_chapter_filter_accepts_list(tmp_path: Path, _fake_transport):
    """``chapter=[1, 2]`` mirrors repeated ``--chapter`` CLI flags."""
    if not FIXTURE_EPUB.exists():
        pytest.skip("fixture EPUB missing")

    structure = ios_entrypoints.convert_epub(
        epub_path=str(FIXTURE_EPUB),
        output_dir=str(tmp_path / "discover_out"),
        cache_dir=str(tmp_path / "discover_cache"),
        show_structure=True,
    )
    indices = [str(m["index"]) for m in structure["manifest"]]
    if len(indices) < 2:
        pytest.skip("fixture has too few chapters")
    targets = [indices[0], indices[1]]

    result = ios_entrypoints.convert_epub(
        epub_path=str(FIXTURE_EPUB),
        output_dir=str(tmp_path / "out"),
        cache_dir=str(tmp_path / "cache"),
        chapter=targets,
    )
    # At minimum, every manifest entry's parent index must be in targets.
    parents = {m["index"].split(".", 1)[0] for m in result["manifest"]}
    for parent in parents:
        assert parent in targets, parent


# ---------------------------------------------------------------------------
# clear_cache + show_structure
# ---------------------------------------------------------------------------


def test_convert_epub_show_structure_returns_book_layout(tmp_path: Path, _fake_transport):
    """``show_structure=True`` must short-circuit -- no synthesis, no
    transport calls, no MP3s on disk. The manifest carries the parsed
    TOC for the UI.
    """
    if not FIXTURE_EPUB.exists():
        pytest.skip("fixture EPUB missing")

    result = ios_entrypoints.convert_epub(
        epub_path=str(FIXTURE_EPUB),
        output_dir=str(tmp_path / "out"),
        cache_dir=str(tmp_path / "cache"),
        show_structure=True,
    )

    assert result["show_structure"] is True
    assert result["outputs"] == []
    assert result["errors"] == []
    assert _fake_transport == [], "show_structure must not synthesise"
    for entry in result["manifest"]:
        assert "index" in entry
        assert "name" in entry
        assert "level" in entry
        assert "char_count" in entry
