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

import os
from pathlib import Path

import pytest

from python_app.src import ios_entrypoints
from python_app.src import paths as paths_module
from python_app.src.tts import _edge_transport, _piper_transport

FIXTURE_EPUB = Path(__file__).parent / "fixtures" / "epubs" / "test_multifeature.epub"


_PATHS_SNAPSHOT_ATTRS = (
    "PERSISTENT_ROOT",
    "CACHE_DIR",
    "OUTPUT_DIR",
    "JOBS_DIR",
    "UPLOADS_DIR",
    "JOB_INPUTS_DIR",
    "SOURCE_BACKUPS_DIR",
    "LOGS_DIR",
    "TELEMETRY_DIR",
)

_ENV_SNAPSHOT_KEYS = (
    "CACHE_DIR",
    "OUTPUT_DIR",
    "PERSISTENT_ROOT",
    "MAX_CHAPTER_CHARS",
)


@pytest.fixture(autouse=True)
def _isolate_ios_entrypoints_state():
    """Every test gets a clean transport, env, and ``paths`` module.

    ``convert_epub`` mutates ``os.environ`` and the in-memory
    ``python_app.src.paths`` module to point cache/output at iOS sandbox
    dirs. Without this fixture those mutations leak into adjacent tests
    -- notably ``test_paths.py`` which calls ``importlib.reload`` and
    sees the leftover env. We snapshot before each test and restore
    after.
    """
    env_snapshot = {k: os.environ.get(k) for k in _ENV_SNAPSHOT_KEYS}
    paths_snapshot = {a: getattr(paths_module, a, None) for a in _PATHS_SNAPSHOT_ATTRS}
    try:
        yield
    finally:
        _edge_transport.reset_transport()
        _piper_transport.reset_transport()
        for key, value in env_snapshot.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        for attr, value in paths_snapshot.items():
            if value is None:
                if hasattr(paths_module, attr):
                    delattr(paths_module, attr)
            else:
                setattr(paths_module, attr, value)


@pytest.fixture
def _fake_transport():
    """Install a deterministic byte-emitting transport for the duration
    of one test. Returns the list of (text, voice) call tuples so
    assertions can verify chunking + voice plumbing.
    """
    calls: list[tuple[str, str]] = []

    def fake(text: str, voice: str) -> bytes:
        calls.append((text, voice))
        # Emit enough bytes per chunk to clear iOS's 5KB sanity check
        # without bloating the test fixture. Pattern is recognisable in
        # hex dumps if the test ever needs forensic debugging.
        return b"FAKEMP3:" + b"X" * 600 + b":" + text[:8].encode("utf-8")

    _edge_transport.set_transport(fake)
    return calls


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
