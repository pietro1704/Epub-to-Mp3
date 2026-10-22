"""Tests for ``python_app.src.ios_entrypoints.convert_epub``.

iOS slice 1a contract:
  * Edge-only -- engine=piper/auto_with_piper_fallback raises clearly.
  * Cache + output dirs are explicit args (no PROJECT_ROOT).
  * Synthesis goes through ``_edge_transport.synthesize_chunk`` so the
    Swift bridge can supply MP3 bytes per chunk without touching aiohttp.
  * Chapter selection, ``clear_cache``, ``show_structure``,
    ``max_chapter_chars`` mirror the CLI semantics.

These tests stay off the network entirely: a fake transport returns
deterministic bytes per chunk so we can prove plumbing without paying
for Edge calls.
"""

from __future__ import annotations

from python_app.tests._ios_entrypoints_test_support import (
    Book as Book,
    Chapter as Chapter,
    EpubParser as EpubParser,
    FIXTURE_EPUB as FIXTURE_EPUB,
    Path as Path,
    SimpleNamespace as SimpleNamespace,
    _ENV_SNAPSHOT_KEYS as _ENV_SNAPSHOT_KEYS,
    _PATHS_SNAPSHOT_ATTRS as _PATHS_SNAPSHOT_ATTRS,
    _edge_transport as _edge_transport,
    _fake_transport as _fake_transport,
    _isolate_ios_entrypoints_state as _isolate_ios_entrypoints_state,
    _piper_transport as _piper_transport,
    ios_entrypoints as ios_entrypoints,
    pytest as pytest,
)

from python_app.tests._ios_entrypoints_selection_projection_cases import (
    test_convert_epub_with_fixture as test_convert_epub_with_fixture,
    test_convert_epub_respects_cache_dir as test_convert_epub_respects_cache_dir,
    test_convert_epub_override_max_chapter_chars as test_convert_epub_override_max_chapter_chars,
    test_convert_epub_chapter_filter as test_convert_epub_chapter_filter,
    test_convert_epub_chapter_filter_accepts_list as test_convert_epub_chapter_filter_accepts_list,
    test_convert_epub_show_structure_returns_book_layout as test_convert_epub_show_structure_returns_book_layout,
)
from python_app.tests._ios_entrypoints_cache_policy_cases import (
    test_convert_epub_clear_cache_resynthesises as test_convert_epub_clear_cache_resynthesises,
    test_convert_epub_without_force_reuses_outputs as test_convert_epub_without_force_reuses_outputs,
    test_convert_epub_no_validate_disables_helper_validation as test_convert_epub_no_validate_disables_helper_validation,
    test_convert_epub_missing_file_raises as test_convert_epub_missing_file_raises,
)
from python_app.tests._ios_entrypoints_piper_fallback_cases import (
    test_convert_epub_accepts_piper_when_installed as test_convert_epub_accepts_piper_when_installed,
    test_synthesize_chapter_falls_back_to_piper_when_edge_raises as test_synthesize_chapter_falls_back_to_piper_when_edge_raises,
    test_synthesize_chapter_without_piper_fallback_propagates_edge_error as test_synthesize_chapter_without_piper_fallback_propagates_edge_error,
    test_synthesize_chapter_piper_fallback_with_no_transport_propagates_edge_error as test_synthesize_chapter_piper_fallback_with_no_transport_propagates_edge_error,
    test_synthesize_chapter_piper_fallback_failure_combines_errors as test_synthesize_chapter_piper_fallback_failure_combines_errors,
)

# ---------------------------------------------------------------------------
# Engine gate
# ---------------------------------------------------------------------------


def test_convert_epub_invalid_engine_raises(tmp_path: Path, _fake_transport):
    """``engine='piper'`` must fail loudly. No silent fallback to Edge,
    no half-completed conversion -- the Carl regression guard.
    """
    if not FIXTURE_EPUB.exists():
        pytest.skip("fixture EPUB missing")

    with pytest.raises(RuntimeError, match="not supported on iOS"):
        ios_entrypoints.convert_epub(
            epub_path=str(FIXTURE_EPUB),
            output_dir=str(tmp_path / "out"),
            cache_dir=str(tmp_path / "cache"),
            engine="piper",
        )


def test_convert_epub_fallback_piper_without_transport_raises(tmp_path: Path, _fake_transport):
    """``fallback_engine='piper'`` is accepted only when a Piper
    transport is installed (slice 1b seam). With no transport wired
    in (the default state on iOS today), the call raises a clear
    error pointing at the bring-up doc.
    """
    if not FIXTURE_EPUB.exists():
        pytest.skip("fixture EPUB missing")

    # Sanity: no piper transport installed.
    assert _piper_transport.get_transport() is None

    with pytest.raises(RuntimeError, match="no piper transport installed"):
        ios_entrypoints.convert_epub(
            epub_path=str(FIXTURE_EPUB),
            output_dir=str(tmp_path / "out"),
            cache_dir=str(tmp_path / "cache"),
            engine="edge",
            fallback_engine="piper",
        )


def test_convert_epub_unknown_fallback_engine_raises(tmp_path: Path, _fake_transport):
    """Anything other than ``none``/``piper`` is rejected outright so
    a typo in the Swift UI can't silently route synthesis somewhere
    unexpected.
    """
    if not FIXTURE_EPUB.exists():
        pytest.skip("fixture EPUB missing")

    with pytest.raises(RuntimeError, match="fallback_engine"):
        ios_entrypoints.convert_epub(
            epub_path=str(FIXTURE_EPUB),
            output_dir=str(tmp_path / "out"),
            cache_dir=str(tmp_path / "cache"),
            engine="edge",
            fallback_engine="kokoro",
        )


def test_convert_epub_engine_auto_is_accepted(tmp_path: Path, _fake_transport):
    """``engine='auto'`` is the UI-friendly alias for Edge in the CLI;
    the iOS entrypoint should treat it the same way (no error).
    """
    if not FIXTURE_EPUB.exists():
        pytest.skip("fixture EPUB missing")

    result = ios_entrypoints.convert_epub(
        epub_path=str(FIXTURE_EPUB),
        output_dir=str(tmp_path / "out"),
        cache_dir=str(tmp_path / "cache"),
        engine="auto",
        chapter=1,
    )
    assert result["errors"] == []
    assert result["outputs"], "auto engine should still produce outputs"


# ---------------------------------------------------------------------------
# _resolve_auto_voice
# ---------------------------------------------------------------------------


def test_resolve_auto_voice_portuguese():
    text = (
        "Ele não sabia o que fazer. Ela estava muito preocupada. Também não entendia para onde ir."
    )
    assert ios_entrypoints._resolve_auto_voice(text) == "pt-BR-FranciscaNeural"


def test_resolve_auto_voice_english():
    text = "He did not know what to do. She was very worried about it."
    assert ios_entrypoints._resolve_auto_voice(text) == "en-US-AriaNeural"


def test_resolve_auto_voice_empty():
    assert ios_entrypoints._resolve_auto_voice("") == "en-US-AriaNeural"


# ---------------------------------------------------------------------------
# Parser-prepared speech payload
# ---------------------------------------------------------------------------


def test_prepare_audible_speech_text_matches_cli_populated_speech_branch():
    """Residual formatting markers use the CLI's no-segment branch."""
    from python_app.src.text_formatting import TextFormattingProcessor

    speech_text = "Chapter one...\n\n[[fmt:italic]]An emphasized phrase[[/fmt]]."
    expected = TextFormattingProcessor().to_audible_text(speech_text, None)

    actual = ios_entrypoints.prepare_audible_speech_text(speech_text)

    assert actual == expected
    assert "[[fmt:" not in actual
    assert "em itálico" in actual


def test_prepare_audible_speech_text_preserves_structural_cues():
    """Already-prepared title pauses survive the final Markdown cleanup."""
    speech_text = "Chapter one...\n\nNarration with _inline markdown_."

    actual = ios_entrypoints.prepare_audible_speech_text(speech_text)

    assert actual == "Chapter one...\n\nNarration with inline markdown."


def test_convert_epub_sends_canonical_speech_text_to_transport(
    tmp_path: Path, _fake_transport, monkeypatch
):
    """In-process conversion must not synthesize the reader-facing raw text."""
    source = tmp_path / "book.epub"
    source.write_text("placeholder")
    speech_text = "Chapter one...\n\nNarration with _inline markdown_."
    chapter = Chapter(
        index=1,
        name="Chapter one",
        source_path="ch1.xhtml",
        text="This reader text must never reach Edge.",
        speech_text=speech_text,
    )
    monkeypatch.setattr(
        EpubParser,
        "parse",
        lambda _parser: Book("Book", "Author", [chapter], language="en"),
    )

    result = ios_entrypoints.convert_epub(
        epub_path=str(source),
        output_dir=str(tmp_path / "out"),
        cache_dir=str(tmp_path / "cache"),
        voice="en-US-AriaNeural",
    )

    assert result["errors"] == []
    assert [text for text, _voice in _fake_transport] == [
        ios_entrypoints.prepare_audible_speech_text(speech_text)
    ]


# ---------------------------------------------------------------------------
# synthesize_chapter_streaming with voice="auto"
# ---------------------------------------------------------------------------


def test_streaming_auto_voice_resolves_to_real_voice(tmp_path: Path):
    """``voice='auto'`` must be resolved before reaching the transport."""
    transport_calls: list[tuple[str, str]] = []

    def spy_transport(text: str, voice: str) -> bytes:
        transport_calls.append((text, voice))
        return b"\xff" * 100

    _edge_transport.set_transport(spy_transport)
    segments: list[tuple[int, int]] = []

    out_path = tmp_path / "chapter.mp3"
    ios_entrypoints.synthesize_chapter_streaming(
        "Hello world. A short test chapter for voice resolution.",
        "auto",
        str(out_path),
        on_segment=lambda data, seg_idx, total: segments.append((seg_idx, len(data))),
    )

    assert out_path.exists()
    assert segments, "no segments delivered"
    for _, voice in transport_calls:
        assert voice != "auto", "voice='auto' leaked to transport"
        assert "Neural" in voice


# ---------------------------------------------------------------------------
# prepare_chunks
# ---------------------------------------------------------------------------


class TestPrepareChunks:
    """Unit tests for ``prepare_chunks`` — the pre-split entrypoint that
    enables Swift-side parallel chunk synthesis."""

    def test_empty_text_returns_empty_list(self):
        result = ios_entrypoints.prepare_chunks("", voice="en-US-AriaNeural")
        assert result["chunks"] == []

    def test_short_text_single_chunk(self):
        result = ios_entrypoints.prepare_chunks("Hello world.", voice="en-US-AriaNeural")
        assert len(result["chunks"]) == 1
        assert result["chunks"][0] == "Hello world."
        assert result["voice"] == "en-US-AriaNeural"

    def test_long_text_splits_into_multiple_chunks(self):
        # 25K chars should produce multiple chunks at 12K default
        text = "A" * 25_000
        result = ios_entrypoints.prepare_chunks(text, voice="en-US-AriaNeural")
        assert len(result["chunks"]) >= 2

    def test_auto_voice_resolved(self):
        pt_text = "Não sei como ele está. Também é isso mesmo. Já falei."
        result = ios_entrypoints.prepare_chunks(pt_text, voice="auto")
        assert "pt-BR" in result["voice"]
        assert result["voice"] != "auto"

    def test_streaming_mode_has_small_first_chunk(self):
        # 5K chars: in streaming mode, first chunk should be ~500 chars,
        # rest in a second chunk.
        text = "A sentence. " * 400  # ~5200 chars
        result = ios_entrypoints.prepare_chunks(text, voice="en-US-AriaNeural", streaming=True)
        assert len(result["chunks"]) >= 2
        # First chunk should be ≤ first_chunk_chars default (500) + slack
        assert len(result["chunks"][0]) <= 600

    def test_non_streaming_mode_uses_full_chunk_size(self, monkeypatch):
        # Chunk preparation is a pure default-policy test. Do not inherit
        # process-level tuning or a prior test's iOS streaming overrides.
        for key in (
            "EDGE_FIRST_CHUNK_CHARS",
            "IOS_EDGE_CHUNK_CHARS",
            "EDGE_MAX_SEGMENT_SECONDS",
            "EXPECTED_WPM",
        ):
            monkeypatch.delenv(key, raising=False)
        text = "A sentence. " * 400  # ~5200 chars
        result = ios_entrypoints.prepare_chunks(text, voice="en-US-AriaNeural", streaming=False)
        # The char limit is not the only CLI bound: 85s at EXPECTED_WPM=200
        # also splits long prose into duration-safe segments.
        assert len(result["chunks"]) >= 2
        assert all(len(chunk) <= 12_000 for chunk in result["chunks"])


def test_audio_completeness_matches_cli_duration_threshold(tmp_path, monkeypatch):
    """The iOS adapter uses the CLI WPM/coverage rule for long chapters."""
    import mutagen.mp3

    output = tmp_path / "chapter.mp3"
    output.write_bytes(b"synthetic")
    monkeypatch.setenv("EXPECTED_WPM", "200")
    monkeypatch.setattr(
        mutagen.mp3,
        "MP3",
        lambda _path: SimpleNamespace(info=SimpleNamespace(length=120.0)),
    )

    complete, coverage = ios_entrypoints._validate_audio_completeness(output, 2000)

    assert complete is True
    assert coverage == 100.0
