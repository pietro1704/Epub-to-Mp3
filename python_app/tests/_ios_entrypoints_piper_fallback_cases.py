"""Piper Fallback regression scenarios, collected by test_ios_entrypoints."""

from __future__ import annotations

from python_app.tests._ios_entrypoints_test_support import FIXTURE_EPUB as FIXTURE_EPUB
from python_app.tests._ios_entrypoints_test_support import Path as Path
from python_app.tests._ios_entrypoints_test_support import _edge_transport as _edge_transport
from python_app.tests._ios_entrypoints_test_support import _piper_transport as _piper_transport
from python_app.tests._ios_entrypoints_test_support import ios_entrypoints as ios_entrypoints
from python_app.tests._ios_entrypoints_test_support import pytest as pytest

# ---------------------------------------------------------------------------
# Piper fallback seam (slice 1b stub)
# ---------------------------------------------------------------------------


def test_convert_epub_accepts_piper_when_installed(tmp_path: Path, _fake_transport):
    """When a Piper transport is installed via
    ``_piper_transport.set_transport``, ``fallback_engine="piper"`` is
    accepted and the chapter manifest entries record the resolved
    Piper language tag. The Edge transport is still primary so no
    Piper call should fire on the happy path; the fixture is well-
    behaved enough that Edge succeeds every chunk.
    """
    if not FIXTURE_EPUB.exists():
        pytest.skip("fixture EPUB missing")

    piper_calls: list[tuple[str, str]] = []

    def fake_piper(text: str, lang: str) -> bytes:
        piper_calls.append((text, lang))
        return b"PIPERFAKE" + b"Y" * 600

    _piper_transport.set_transport(fake_piper)

    result = ios_entrypoints.convert_epub(
        epub_path=str(FIXTURE_EPUB),
        output_dir=str(tmp_path / "out"),
        cache_dir=str(tmp_path / "cache"),
        engine="edge",
        fallback_engine="piper",
        chapter=1,
    )

    assert result["errors"] == []
    completed = [m for m in result["manifest"] if m.get("status") == "completed"]
    assert completed, "expected at least one completed chapter"
    # Edge fixture works fine — Piper fallback should not have fired.
    assert piper_calls == []
    # Every completed entry records the language the Piper fallback
    # would target if needed (BCP-47 form, not the Edge voice name).
    for entry in completed:
        assert entry.get("piper_fallback_lang") in {"pt-BR", "en-US"}


def test_synthesize_chapter_falls_back_to_piper_when_edge_raises(tmp_path: Path):
    """Per-chunk fallback: if the Edge transport raises and a Piper
    transport is installed, the chunk is retried through Piper. The
    written file is the concatenation of all transport results.
    """
    edge_calls: list[tuple[str, str]] = []
    piper_calls: list[tuple[str, str]] = []

    def failing_edge(text: str, voice: str) -> bytes:
        edge_calls.append((text, voice))
        raise RuntimeError("edge: simulated network failure")

    def working_piper(text: str, lang: str) -> bytes:
        piper_calls.append((text, lang))
        return b"PIPER-" + text[:8].encode() + b"-" + lang.encode()

    _edge_transport.set_transport(failing_edge)
    _piper_transport.set_transport(working_piper)

    out_path = tmp_path / "chapter.mp3"
    result = ios_entrypoints.synthesize_chapter_via_transport(
        "hello world. this is a short chapter.",
        "en-US-AriaNeural",
        str(out_path),
        piper_fallback_lang="en-US",
    )

    assert result == str(out_path)
    assert out_path.exists()
    assert out_path.stat().st_size > 0
    # Edge was attempted at least once per chunk; Piper covered the failures.
    assert edge_calls, "edge transport never invoked"
    assert piper_calls, "piper fallback never invoked"
    # The file bytes are the concatenated Piper output (Edge produced none).
    expected = b"".join(b"PIPER-" + t[:8].encode() + b"-en-US" for t, _ in piper_calls)
    assert out_path.read_bytes() == expected


def test_synthesize_chapter_without_piper_fallback_propagates_edge_error(
    tmp_path: Path,
):
    """If ``piper_fallback_lang`` is ``None``, Edge errors propagate
    unchanged -- the seam exists but is opt-in.
    """

    def failing_edge(text: str, voice: str) -> bytes:
        raise RuntimeError("edge: simulated failure")

    _edge_transport.set_transport(failing_edge)
    # Even if a Piper transport is installed, omitting ``piper_fallback_lang``
    # must not silently engage it.
    _piper_transport.set_transport(lambda t, lang: b"PIPER")

    out_path = tmp_path / "chapter.mp3"
    with pytest.raises(RuntimeError, match="edge: simulated failure"):
        ios_entrypoints.synthesize_chapter_via_transport(
            "hello world", "en-US-AriaNeural", str(out_path)
        )
    assert not out_path.exists()


def test_synthesize_chapter_piper_fallback_with_no_transport_propagates_edge_error(
    tmp_path: Path,
):
    """``piper_fallback_lang`` is set but no Piper transport installed:
    fallback is effectively a no-op (the seam is forward-compatible),
    so the original Edge error surfaces unchanged. The
    ``convert_epub`` gate refuses to even reach this state -- it
    rejects ``fallback_engine="piper"`` when no transport is wired in
    -- but the lower-level helper is robust to being called directly.
    """

    def failing_edge(text: str, voice: str) -> bytes:
        raise RuntimeError("edge: simulated failure")

    _edge_transport.set_transport(failing_edge)
    assert _piper_transport.get_transport() is None

    out_path = tmp_path / "chapter.mp3"
    with pytest.raises(RuntimeError, match="edge: simulated failure"):
        ios_entrypoints.synthesize_chapter_via_transport(
            "hello world",
            "en-US-AriaNeural",
            str(out_path),
            piper_fallback_lang="en-US",
        )
    assert not out_path.exists()


def test_synthesize_chapter_piper_fallback_failure_combines_errors(tmp_path: Path):
    """Edge raises AND a Piper transport is installed but also raises:
    the wrapper combines both errors so the operator can see exactly
    which engine layer failed. This is the "both engines hard-dead"
    diagnostic path.
    """

    def failing_edge(text: str, voice: str) -> bytes:
        raise RuntimeError("edge: simulated failure")

    def failing_piper(text: str, lang: str) -> bytes:
        raise RuntimeError("piper: model not loaded")

    _edge_transport.set_transport(failing_edge)
    _piper_transport.set_transport(failing_piper)

    out_path = tmp_path / "chapter.mp3"
    with pytest.raises(RuntimeError, match="edge failed and piper fallback failed"):
        ios_entrypoints.synthesize_chapter_via_transport(
            "hello world",
            "en-US-AriaNeural",
            str(out_path),
            piper_fallback_lang="en-US",
        )
    assert not out_path.exists()
