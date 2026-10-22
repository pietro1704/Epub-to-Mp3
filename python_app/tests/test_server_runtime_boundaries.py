"""Signature, module identity and isolated chapter coordinator contracts."""

from __future__ import annotations

import asyncio
import contextlib
import inspect
import time
from types import SimpleNamespace
from unittest import IsolatedAsyncioTestCase, TestCase
from unittest.mock import AsyncMock, Mock, patch

from python_app.src import server_chapter_run as coordinator
from python_app.src.conversion_control import ConversionControl
from python_app.src.server_chapter_state import ServerChapterState
from python_app.src.server_runtime_binding import bind_server_function


def echo_implementation(runtime, value: int = 1) -> int:
    return runtime.transform(value)


async def async_implementation(runtime, value: int) -> object:
    return await runtime.transform(value)


class ServerRuntimeBindingTests(TestCase):
    def test_bound_signature_resolves_annotations_and_preserves_defaults(self):
        runtime = SimpleNamespace(__name__="server", transform=lambda value: value)
        bound = bind_server_function(echo_implementation, runtime)
        signature = inspect.signature(bound)
        self.assertEqual(list(signature.parameters), ["value"])
        self.assertIs(signature.parameters["value"].annotation, int)
        self.assertEqual(signature.parameters["value"].default, 1)
        self.assertIs(signature.return_annotation, int)
        self.assertEqual(bound.__module__, "server")
        self.assertEqual(bound(), 1)

    def test_bound_function_observes_current_facade_patch(self):
        runtime = SimpleNamespace(__name__="python_app.server", transform=lambda value: value)
        bound = bind_server_function(echo_implementation, runtime)
        runtime.transform = lambda value: value + 10
        self.assertEqual(bound(2), 12)


class ServerAsyncBoundaryTests(IsolatedAsyncioTestCase):
    async def test_async_binding_preserves_identity_failure_and_cancellation(self):
        marker = object()
        runtime = SimpleNamespace(__name__="server", transform=AsyncMock(return_value=marker))
        bound = bind_server_function(async_implementation, runtime)
        self.assertTrue(inspect.iscoroutinefunction(bound))
        self.assertIs(await bound(1), marker)
        runtime.transform.side_effect = ValueError("transport failed")
        with self.assertRaisesRegex(ValueError, "transport failed"):
            await bound(1)
        runtime.transform.side_effect = asyncio.CancelledError
        with self.assertRaises(asyncio.CancelledError):
            await bound(1)

    def make_session(self):
        return SimpleNamespace(
            job_failed={"value": False},
            _should_abort_current_run=lambda: False,
            _note_chapter_attempt=lambda _index: 1,
            chapters=[object(), object()],
            job={"parallelActive": 0},
        )

    def make_runtime(self):
        return SimpleNamespace(
            time=time,
            asyncio=asyncio,
            contextlib=contextlib,
            _update_job_activity=Mock(),
        )

    async def test_parallel_chapters_keep_independent_live_state(self):
        session = self.make_session()
        runtime = self.make_runtime()
        objects = [SimpleNamespace(name="First"), SimpleNamespace(name="Second")]
        states = [
            ServerChapterState(idx=index, chapter_obj=chapter, preferred_engine=None)
            for index, chapter in enumerate(objects, 1)
        ]

        async def complete(_runtime, _session, chapter):
            await asyncio.sleep(0)
            self.assertEqual(chapter.chapter_name, chapter.chapter_obj.name)
            return ConversionControl("return", chapter.chapter_obj)

        with patch.object(coordinator, "_server_chapter_preparation", complete):
            results = await asyncio.gather(
                *(coordinator._server_chapter_run(runtime, session, state) for state in states)
            )
        for result, expected, state in zip(results, objects, states):
            self.assertIs(result.value, expected)
            self.assertTrue(state.heartbeat_stop.is_set())
        self.assertIsNot(states[0].heartbeat_stop, states[1].heartbeat_stop)
        self.assertEqual(session.job["parallelActive"], 0)

    async def test_cancelled_chapter_cleans_activity_and_propagates(self):
        session = self.make_session()
        state = ServerChapterState(
            idx=1, chapter_obj=SimpleNamespace(name="First"), preferred_engine=None
        )
        with patch.object(
            coordinator,
            "_server_chapter_preparation",
            AsyncMock(side_effect=asyncio.CancelledError),
        ):
            with self.assertRaises(asyncio.CancelledError):
                await coordinator._server_chapter_run(self.make_runtime(), session, state)
        self.assertTrue(state.heartbeat_stop.is_set())
        self.assertEqual(session.job["parallelActive"], 0)
        self.assertNotIn("statusHint", session.job)
