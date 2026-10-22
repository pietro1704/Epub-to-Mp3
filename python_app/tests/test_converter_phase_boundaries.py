"""Cleanup and identity contracts at the chapter coordinator boundary."""

import asyncio
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest import IsolatedAsyncioTestCase, TestCase
from unittest.mock import AsyncMock, Mock, patch

from python_app.src import converter as runtime
from python_app.src import chapter_conversion_run as coordinator
from python_app.src.chapter_conversion_state import ChapterConversionState
from python_app.src.config import ConversionConfig
from python_app.src.conversion_control import ConversionControl
from python_app.src.converter_models import ChapterConversionOutcome, ConversionResult
from python_app.src.ebook_reader import Chapter


class ConverterModelIdentityTests(TestCase):
    def test_public_outcomes_keep_one_identity(self):
        self.assertIs(runtime.ConversionResult, ConversionResult)
        self.assertIs(runtime.ChapterConversionOutcome, ChapterConversionOutcome)


class ChapterCoordinatorCleanupTests(IsolatedAsyncioTestCase):
    async def run_case(self, directory, synthesis):
        output = Path(directory) / "chapter.mp3"
        progress = Mock()
        converter = SimpleNamespace(
            verbose=False,
            loc=SimpleNamespace(t=lambda key: key),
            file_manager=SimpleNamespace(get_temp_output_path=lambda *_args: output),
            _resolve_pre_tts_payload=lambda *_args: ("Chapter body.", None, False),
            _announce_stage=Mock(),
        )
        semaphore = asyncio.Semaphore(1)
        state = ChapterConversionState(
            semaphore=semaphore,
            chapter=Chapter(1, "Chapter", "chapter.xhtml", "Chapter body."),
            tts_engine=object(),
            output_dir=Path(directory),
            index=1,
            config=ConversionConfig(engine="edge"),
            progress=progress,
        )
        with (
            patch.object(coordinator, "_parallel_chapter_synthesis", synthesis),
            patch.object(coordinator, "_parallel_chapter_audio_validation", AsyncMock()) as validation,
        ):
            try:
                result = await coordinator._chapter_conversion_run(converter, state)
            finally:
                self.assertEqual(semaphore._value, 1)
                self.assertTrue(state.heartbeat_stop.is_set())
                self.assertTrue(state.heartbeat_task.done())
                progress.complete_chapter.assert_called_once()
                validation.assert_not_awaited()
        return result

    async def test_success_preserves_return_identity_and_releases_resources(self):
        expected = Path("complete.mp3")
        with TemporaryDirectory() as directory:
            result = await self.run_case(
                directory, AsyncMock(return_value=ConversionControl("return", expected))
            )
        self.assertIs(result.value, expected)

    async def test_failure_keeps_error_cause_and_releases_resources(self):
        failure = ValueError("transport failed")
        with TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RuntimeError, "transport failed") as raised:
                await self.run_case(directory, AsyncMock(side_effect=failure))
        self.assertIs(raised.exception.__cause__.__cause__, failure)

    async def test_cancellation_propagates_and_releases_resources(self):
        with TemporaryDirectory() as directory:
            with self.assertRaises(asyncio.CancelledError):
                await self.run_case(directory, AsyncMock(side_effect=asyncio.CancelledError))
