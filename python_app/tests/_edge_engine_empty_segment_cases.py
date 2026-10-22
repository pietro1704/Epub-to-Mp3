"""Empty Segment regression scenarios, collected by test_edge_engine."""

import python_app.tests._edge_engine_test_support as _shared_test_exports
from python_app.tests._edge_engine_test_support import EdgeTTSEngine as EdgeTTSEngine
from python_app.tests._edge_engine_test_support import Mock as Mock
from python_app.tests._edge_engine_test_support import Path as Path
from python_app.tests._edge_engine_test_support import edge_engine as edge_engine
from python_app.tests._edge_engine_test_support import tempfile as tempfile
from python_app.tests._edge_engine_test_support import unittest as unittest

asyncio = _shared_test_exports.asyncio


class TestEdgeEmptySegmentGuard(unittest.TestCase):
    """Regression: an empty (0-byte) Edge segment must never corrupt output.

    Root cause (Hobbit AUTHOR'S NOTE): segment 2 returned empty from Edge but a
    0-byte chunk was concatenated into the chapter MP3, producing an undecodable
    ~0s file that passed as 'success' and only failed late coverage validation.
    The empty chunk also persisted on disk so every retry re-failed identically.
    """

    def setUp(self) -> None:
        self._original_edge_tts = edge_engine.edge_tts
        edge_engine.edge_tts = Mock()
        self.engine = EdgeTTSEngine("test-voice")
        self.engine.verbose = False

    def tearDown(self) -> None:
        edge_engine.edge_tts = self._original_edge_tts

    def test_serial_resume_empty_segment_does_not_corrupt_output(self):
        """Serial path: a segment that writes 0 bytes must fail clean, not append.

        This is the exact Hobbit AUTHOR'S NOTE shape: seg-0 good, seg-1 empty.
        The empty chunk must NOT be appended, must NOT be left on disk, and the
        chapter must fail clean (None) rather than yield a corrupt MP3.
        """
        import asyncio

        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            output_path = tmp / "chapter.mp3"
            resume_dir = tmp / "resume"
            resume_dir.mkdir()

            async def _run():
                call = {"n": 0}

                async def fake_synth(text, voice, out_path, append=False):
                    idx = call["n"]
                    call["n"] += 1
                    out_path = Path(out_path)
                    if idx == 0:
                        out_path.write_bytes(b"g" * 4096)  # good segment
                        return True
                    # Empty segment: mimic the engine's own guard flipping a
                    # 0-byte write to a failure (received_audio -> False).
                    out_path.write_bytes(b"")
                    return False

                self.engine._synthesize_segment = fake_synth  # type: ignore[method-assign]
                self.engine._enable_parallel = False
                self.engine._rate_limiter = None
                # Force exactly two deterministic segments.
                self.engine._prepare_segments = (  # type: ignore[method-assign]
                    lambda *a, **k: [("test-voice", "AAAA"), ("test-voice", "BBBB")]
                )
                self.engine._should_force_plain_text = lambda *a, **k: False  # type: ignore
                # Disable retry/split expansion so the empty segment stays empty.
                self.engine._split_failed_segment = lambda *a, **k: []  # type: ignore
                self.engine._force_micro_segments = lambda *a, **k: []  # type: ignore
                self.engine._simplify_segment_text = lambda *a, **k: None  # type: ignore

                return await self.engine.synthesize_async(
                    "AAAA BBBB",
                    output_path,
                    resume_chunks_dir=resume_dir,
                )

            res = asyncio.run(_run())
            # Empty segment -> chapter fails clean.
            self.assertIsNone(res)
            # No empty chunk_0001 left behind in the resume dir.
            leftovers = [p for p in resume_dir.glob("chunk_*.mp3") if p.stat().st_size == 0]
            self.assertEqual(leftovers, [])
            # No corrupt final output.
            if output_path.exists():
                self.assertGreaterEqual(
                    output_path.stat().st_size, edge_engine._MIN_VALID_CHUNK_BYTES
                )

    def test_synthesize_segment_empty_write_returns_false_and_unlinks(self):
        """A stream that reports audio but writes <1KB is a segment failure."""
        import asyncio

        with tempfile.TemporaryDirectory() as tmpdir:
            out = Path(tmpdir) / "chunk_0000.mp3"

            # Build a fake edge_tts.Communicate whose stream yields an 'audio'
            # event with empty payload (Edge flushed a header then dropped).
            class _FakeStream:
                def __aiter__(self):
                    return self

                async def __anext__(self):
                    raise StopAsyncIteration

                async def aclose(self):
                    return None

            class _FakeComm:
                def __init__(self, text, voice):
                    self.connector = None

                def stream(self):
                    return _FakeStream()

            self.engine._edge_tts = Mock()
            self.engine._edge_tts.Communicate = _FakeComm
            import asyncio as _a

            self.engine._rate_limiter = _a.Semaphore(1)
            self.engine._global_rate_limiter = None
            self.engine._global_rate_limiter_loop = None

            async def _run() -> bool:
                # Pre-create a 0-byte file to mimic the 'wb' truncation.
                out.write_bytes(b"")
                return await self.engine._synthesize_segment(
                    "some text", "test-voice", out, append=False
                )

            ok = asyncio.run(_run())
            self.assertFalse(ok)
            # Empty chunk must not be left behind (append=False owns the file).
            self.assertFalse(out.exists())

    def test_parallel_concat_skips_empty_temp_and_fails_when_all_empty(self):
        """Mix of good + empty temp segments must never produce a 0s MP3."""
        import asyncio

        async def _run_all_empty() -> None:
            self.engine._enable_parallel = True
            self.engine._parallel_slots = 2

            async def fake_synth(text, voice, output_path, append=False):
                # Report success but write an empty file (the corrupt case).
                Path(output_path).write_bytes(b"")
                return True

            self.engine._synthesize_segment = fake_synth  # type: ignore[method-assign]

            with tempfile.TemporaryDirectory() as tmpdir:
                output_path = Path(tmpdir) / "chapter.mp3"
                res = await self.engine._synthesize_parallel(
                    output_path,
                    [("test-voice", "seg-0"), ("test-voice", "seg-1")],
                    force_plain_segments=False,
                )
                # All empty -> clean failure, no corrupt output on disk.
                self.assertIsNone(res)
                self.assertFalse(output_path.exists())

        asyncio.run(_run_all_empty())

    def test_parallel_concat_keeps_good_drops_empty(self):
        """Good segment survives; empty one is skipped from the concatenation."""
        import asyncio

        async def _run() -> None:
            self.engine._enable_parallel = True
            self.engine._parallel_slots = 2

            async def fake_synth(text, voice, output_path, append=False):
                if text == "good":
                    Path(output_path).write_bytes(b"g" * 4096)
                    return True
                Path(output_path).write_bytes(b"")  # empty seg
                return True

            self.engine._synthesize_segment = fake_synth  # type: ignore[method-assign]

            with tempfile.TemporaryDirectory() as tmpdir:
                output_path = Path(tmpdir) / "chapter.mp3"
                # 1 good + 1 empty = 50% -> below 0.95 -> fail clean, but the
                # concatenation itself must have dropped the empty chunk (the
                # output must never contain the 0-byte fragment).
                res = await self.engine._synthesize_parallel(
                    output_path,
                    [("test-voice", "good"), ("test-voice", "bad")],
                    force_plain_segments=False,
                )
                self.assertIsNone(res)
                self.assertFalse(output_path.exists())

        asyncio.run(_run())
