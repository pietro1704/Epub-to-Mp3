"""Runtime contracts for extracted Edge control and synthesis components."""

import asyncio
from pathlib import Path
from unittest import IsolatedAsyncioTestCase, TestCase
from unittest.mock import AsyncMock, patch

from python_app.src.tts import edge_engine as runtime
from python_app.src.tts.edge_adaptive_control import get_adaptive_chunk_size
from python_app.src.tts.edge_segment_policy import AdaptiveSegmentDurationPolicy


class EdgeControlBoundaryTests(TestCase):
    def test_public_helpers_read_the_facade_state_at_call_time(self):
        self.assertIs(runtime.get_adaptive_chunk_size, get_adaptive_chunk_size)
        self.assertIs(runtime.AdaptiveSegmentDurationPolicy, AdaptiveSegmentDurationPolicy)
        with patch.object(runtime, "_edge_current_chunk_size", 3456):
            self.assertEqual(runtime.get_adaptive_chunk_size(), 3456)

    def test_segment_policy_uses_current_facade_limits(self):
        with patch.object(runtime, "MAX_EDGE_SEGMENT_SECONDS", 100.0):
            policy = AdaptiveSegmentDurationPolicy(
                enabled=True, initial_seconds=85, hard_max_seconds=180, promote_after=1
            )
            self.assertEqual(policy.hard_max_seconds, 100.0)
            self.assertEqual(policy.observe_chapter(success=True)["target_seconds"], 100.0)
            self.assertEqual(policy.observe_chapter(success=False)["target_seconds"], 85.0)
            policy.restore({"target_seconds": "invalid"})
            self.assertEqual(policy.target_seconds, 85.0)


class EdgeSynthesisBoundaryTests(IsolatedAsyncioTestCase):
    def make_engine(self):
        engine = runtime.EdgeTTSEngine.__new__(runtime.EdgeTTSEngine)
        engine._pending_segment_policy_result = None
        engine.last_error = None
        engine._segment_duration_policy = AdaptiveSegmentDurationPolicy(
            enabled=False, initial_seconds=85, hard_max_seconds=180
        )
        return engine

    async def test_shared_limiter_keeps_loop_identity(self):
        loop = asyncio.get_running_loop()
        with patch.object(runtime, "_edge_rate_limiters", {}):
            first = runtime._get_global_edge_limiter(loop)
            self.assertIs(first, runtime._get_global_edge_limiter(loop))
            self.assertIs(runtime._edge_rate_limiters[id(loop)], first)

    async def test_success_preserves_output_identity(self):
        engine = self.make_engine()
        target = Path("chapter.mp3")
        engine._synthesize_async_impl = AsyncMock(return_value=target)
        self.assertIs(await engine.synthesize_async("text", target), target)
        self.assertEqual(engine._pending_segment_policy_result, (True, ""))

    async def test_failure_defers_policy_until_next_chapter(self):
        engine = self.make_engine()
        engine.last_error = "request timeout"
        engine._synthesize_async_impl = AsyncMock(return_value=None)
        self.assertIsNone(await engine.synthesize_async("text", Path("chapter.mp3")))
        self.assertEqual(engine._pending_segment_policy_result, (False, "timeout"))

    async def test_cancellation_propagates_and_records_failure(self):
        engine = self.make_engine()
        engine._synthesize_async_impl = AsyncMock(side_effect=asyncio.CancelledError)
        with self.assertRaises(asyncio.CancelledError):
            await engine.synthesize_async("text", Path("chapter.mp3"))
        self.assertEqual(engine._pending_segment_policy_result, (False, "chapter_failure"))
