"""Cache Policy regression scenarios, collected by test_ios_entrypoints."""

from __future__ import annotations

from python_app.tests._ios_entrypoints_test_support import (
    FIXTURE_EPUB as FIXTURE_EPUB,
    Path as Path,
    _fake_transport as _fake_transport,
    ios_entrypoints as ios_entrypoints,
    pytest as pytest,
)

def test_convert_epub_clear_cache_resynthesises(tmp_path: Path, _fake_transport):
    """``clear_cache=True`` must force re-synthesis: even though the
    first run leaves MP3s on disk, the second invocation should still
    invoke the transport.
    """
    if not FIXTURE_EPUB.exists():
        pytest.skip("fixture EPUB missing")

    first = ios_entrypoints.convert_epub(
        epub_path=str(FIXTURE_EPUB),
        output_dir=str(tmp_path / "out"),
        cache_dir=str(tmp_path / "cache"),
        chapter=1,
    )
    initial_calls = len(_fake_transport)
    assert first["outputs"]
    assert initial_calls > 0

    second = ios_entrypoints.convert_epub(
        epub_path=str(FIXTURE_EPUB),
        output_dir=str(tmp_path / "out"),
        cache_dir=str(tmp_path / "cache"),
        chapter=1,
        clear_cache=True,
    )
    assert len(_fake_transport) > initial_calls, "clear_cache must trigger re-synthesis"
    # All entries should be ``completed``, never ``cached`` after a clear.
    statuses = {m.get("status") for m in second["manifest"]}
    assert "cached" not in statuses


def test_convert_epub_without_force_reuses_outputs(tmp_path: Path, _fake_transport):
    """A second invocation without ``clear_cache`` / ``force_reprocess``
    must reuse MP3s on disk and SKIP the transport. Mirrors the CLI's
    output-reuse guard.
    """
    if not FIXTURE_EPUB.exists():
        pytest.skip("fixture EPUB missing")

    ios_entrypoints.convert_epub(
        epub_path=str(FIXTURE_EPUB),
        output_dir=str(tmp_path / "out"),
        cache_dir=str(tmp_path / "cache"),
        chapter=1,
    )
    calls_after_first = len(_fake_transport)

    result = ios_entrypoints.convert_epub(
        epub_path=str(FIXTURE_EPUB),
        output_dir=str(tmp_path / "out"),
        cache_dir=str(tmp_path / "cache"),
        chapter=1,
    )

    # Transport must not have been invoked for already-rendered chapters.
    assert len(_fake_transport) == calls_after_first
    cached = [m for m in result["manifest"] if m.get("status") == "cached"]
    assert cached, "expected at least one chapter reused from disk"


def test_convert_epub_no_validate_disables_helper_validation(
    tmp_path: Path, _fake_transport, monkeypatch
):
    """The CLI-compatible flag must reach the synthesis helper unchanged."""
    if not FIXTURE_EPUB.exists():
        pytest.skip("fixture EPUB missing")

    received_validation_flags: list[bool] = []
    original = ios_entrypoints.synthesize_chapter_via_transport

    def observe_validation(*args, **kwargs):
        received_validation_flags.append(kwargs["validate_audio"])
        return original(*args, **kwargs)

    monkeypatch.setattr(ios_entrypoints, "synthesize_chapter_via_transport", observe_validation)

    result = ios_entrypoints.convert_epub(
        epub_path=str(FIXTURE_EPUB),
        output_dir=str(tmp_path / "out"),
        cache_dir=str(tmp_path / "cache"),
        chapter=1,
        no_validate=True,
        validate_audio=False,
    )

    assert result["outputs"]
    assert received_validation_flags == [False]


# ---------------------------------------------------------------------------
# Missing input
# ---------------------------------------------------------------------------


def test_convert_epub_missing_file_raises(tmp_path: Path):
    """Caller bug or stale path -- raise ``FileNotFoundError`` so the UI
    surfaces a clear message instead of a generic Python trap.
    """
    with pytest.raises(FileNotFoundError):
        ios_entrypoints.convert_epub(
            epub_path=str(tmp_path / "does-not-exist.epub"),
            output_dir=str(tmp_path / "out"),
            cache_dir=str(tmp_path / "cache"),
        )
