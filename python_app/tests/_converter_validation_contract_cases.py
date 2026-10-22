"""Validation Contract regression scenarios, collected by test_converter."""

from python_app.tests._converter_test_support import AsyncMock as AsyncMock
from python_app.tests._converter_test_support import AudioConverter as AudioConverter
from python_app.tests._converter_test_support import AudioValidator as AudioValidator
from python_app.tests._converter_test_support import CacheManager as CacheManager
from python_app.tests._converter_test_support import Chapter as Chapter
from python_app.tests._converter_test_support import ConversionConfig as ConversionConfig
from python_app.tests._converter_test_support import MockTTSEngine as MockTTSEngine
from python_app.tests._converter_test_support import Path as Path
from python_app.tests._converter_test_support import TextValidator as TextValidator
from python_app.tests._converter_test_support import asyncio as asyncio
from python_app.tests._converter_test_support import datetime as datetime
from python_app.tests._converter_test_support import json as json
from python_app.tests._converter_test_support import patch as patch
from python_app.tests._converter_test_support import re as re
from python_app.tests._converter_test_support import tempfile as tempfile
from python_app.tests._converter_test_support import timezone as timezone
from python_app.tests._converter_test_support import unittest as unittest
from python_app.tests._converter_test_support import warnings as warnings


class TestConverterValidationContract(unittest.IsolatedAsyncioTestCase):
    """Exercise optional validation through the actual chapter conversion method."""

    async def asyncSetUp(self):
        self._baseline_tasks = set(asyncio.all_tasks())
        self.directory = tempfile.TemporaryDirectory(prefix="converter-validation-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.output = self.root / "output"
        self.output.mkdir()
        self.book = self.root / "owned-book.epub"
        self.book.write_bytes(b"owned book identity fixture")
        self.sentinel = self.root / "foreign-book.json"
        self.sentinel.write_bytes(b"preserved outside conversion output and cache")
        self.original_sentinel = self.sentinel.read_bytes()
        self.cache = CacheManager(cache_dir=self.root / "cache")
        self.enterContext(patch("src.converter.CacheManager", return_value=self.cache))
        self.converter = AudioConverter()
        self.converter._current_book_path = self.book
        self.chapter = Chapter(7, "Owned validation chapter", "owned.html", "Narration fixture. " * 350)
        self.config = ConversionConfig(
            engine="edge", voice="fixture-only", output_dir=self.output,
            cache_dir=self.cache.cache_dir, bitrate="8k", validate_audio=True,
            validate_text=False, force_reprocess=True, listen=False,
            verify_transcription=False, auto_validate_output=False, auto_fix_output=False,
        )
        self.converter._active_config = self.config
        self.semaphore = asyncio.Semaphore(1)
        self.audio = self.converter.file_manager.get_temp_output_path(
            self.chapter.name, self.output, 7
        )
        self.wav = self.audio.with_suffix(".wav")
        self.log = self.cache.get_validation_log_path(self.book, 7)
        self.payload = self.chapter.text
        self.marker = b"valid"
        self.engine = MockTTSEngine()
        self.engine.synthesize_async = AsyncMock(side_effect=self._synthesize)
        self.converter.audio_processor.convert_to_mp3 = AsyncMock(side_effect=self._convert_audio)
        self.converter.audio_processor.play_audio = AsyncMock(
            side_effect=AssertionError("Validation fixtures must not play audio")
        )
        self.validator_probe = self.enterContext(
            patch.object(AudioValidator, "get_audio_duration", side_effect=self._duration)
        )
        self.enterContext(patch.object(self.converter, "_probe_audio_duration", side_effect=self._duration))
        self.converter._attempt_segment_retry = AsyncMock(return_value=False)
        self.announcements = self.enterContext(
            patch.object(self.converter, "_announce_stage", wraps=self.converter._announce_stage)
        )
        self.enterContext(warnings.catch_warnings())
        warnings.simplefilter("error", DeprecationWarning)

    def _write_audio(self, path, marker):
        # Derive sufficient owned bytes from the actual payload and existing policy.
        seconds = TextValidator.estimate_duration(self.payload)
        size = max(2048, self.converter._expected_audio_bytes(seconds, self.config.bitrate) or 0)
        self.assertLessEqual(size, 2 * 1024 * 1024, "Fixture unexpectedly exceeded its byte budget")
        Path(path).write_bytes(marker + b"\0" * size)

    async def _synthesize(self, text, output_path, formatting_segments=None):
        self.payload = text
        self.assertGreaterEqual(len(re.sub(r"\s+", " ", text).strip()), 5000)
        Path(output_path).write_bytes(b"owned fake WAV")
        return Path(output_path)

    async def _convert_audio(self, source, destination, **kwargs):
        self.assertEqual(Path(source), self.wav)
        self.assertTrue(self.wav.exists())
        self._write_audio(destination, self.marker)
        return Path(destination)

    def _duration(self, path):
        path = Path(path)
        self.assertEqual(path, self.audio, "The media probe must retain output identity")
        marker = path.read_bytes()[:16]
        if marker.startswith(b"invalid-file"):
            return None
        expected = AudioValidator().estimate_duration(self.payload)
        return expected * 2 if marker.startswith(b"invalid-duration") else expected

    async def _run_chapter(self):
        self.before = datetime.now(timezone.utc)
        result = await asyncio.wait_for(
            self.converter._convert_single_chapter(
                self.semaphore, self.chapter, self.engine, self.output, 7, config=self.config
            ),
            timeout=5,
        )
        self.after = datetime.now(timezone.utc)
        return result

    def _assert_log(self, valid):
        self.assertTrue(self.log.is_file(), "Conversion must persist the actual validation receipt")
        report = json.loads(self.log.read_text(encoding="utf-8"))
        self.assertEqual(report["chapter_number"], 7)
        self.assertEqual(report["chapter_title"], self.chapter.name)
        self.assertEqual(report["text_length"], len(self.payload))
        self.assertEqual(report["is_valid"], valid)
        expected = AudioValidator().estimate_duration(self.payload)
        self.assertEqual(report["expected_duration"], expected)
        self.assertEqual(report["actual_duration"], expected if valid else expected * 2)
        if valid:
            self.assertIsNone(report["message"])
        else:
            self.assertIn("Duration mismatch:", report["message"])
        saved = datetime.fromisoformat(report["validated_at"])
        self.assertIsNone(saved.tzinfo, "Keep the legacy naive ISO wire format")
        self.assertLessEqual(self.before, saved.replace(tzinfo=timezone.utc))
        self.assertLessEqual(saved.replace(tzinfo=timezone.utc), self.after)

    def _pending_owned_tasks(self):
        current = asyncio.current_task()
        return [
            task for task in asyncio.all_tasks()
            if task is not current and task not in self._baseline_tasks and not task.done()
        ]

    async def asyncTearDown(self):
        pending = self._pending_owned_tasks()
        try:
            self.assertEqual(self.sentinel.read_bytes(), self.original_sentinel)
            self.converter.audio_processor.play_audio.assert_not_awaited()
            self.assertFalse(self.semaphore.locked(), "The conversion semaphore must be released")
            self.assertEqual(pending, [], "No task created by this conversion may outlive it")
        finally:
            # Only this test's new tasks belong to cleanup; pre-existing tasks
            # remain untouched even when an assertion fails.
            for task in pending:
                task.cancel()
            await asyncio.gather(*pending, return_exceptions=True)

    async def test_owned_task_probe_detects_a_live_task_after_extraction(self):
        pending = asyncio.create_task(asyncio.Event().wait())
        try:
            await asyncio.sleep(0)
            self.assertIn(pending, self._pending_owned_tasks())
        finally:
            pending.cancel()
            await asyncio.gather(pending, return_exceptions=True)
        self.assertNotIn(pending, self._pending_owned_tasks())

    async def test_valid_long_chapter_persists_real_validation_json_and_naive_utc(self):
        result = await self._run_chapter()
        self.assertEqual(result.path, self.audio)
        self.assertIsNone(result.error)
        self.engine.synthesize_async.assert_awaited_once()
        self.converter._attempt_segment_retry.assert_not_awaited()
        self.assertGreaterEqual(self.validator_probe.call_count, 2)
        self.assertFalse(self.wav.exists())
        self._assert_log(True)

    async def _invalid_file(self, strict):
        self.marker = b"invalid-file"
        self.config.strict_validate = strict
        result = await self._run_chapter()
        self.converter._attempt_segment_retry.assert_awaited_once_with(
            self.engine, 7, self.chapter.name, self.audio, config=self.config
        )
        self.assertFalse(self.log.exists(), "An invalid file has no duration-validation receipt")
        self.assertFalse(self.wav.exists())
        self.assertEqual(self.audio.exists(), not strict)
        self.assertEqual(result.path, None if strict else self.audio)
        self.assertEqual(result.error, "Invalid audio" if strict else None)

    async def test_invalid_file_strict_rejects_after_retry(self):
        await self._invalid_file(True)

    async def test_invalid_file_non_strict_preserves_owned_output(self):
        await self._invalid_file(False)

    async def _invalid_duration(self, strict):
        self.marker = b"invalid-duration"
        self.config.strict_validate = strict
        self.converter.verbose = True
        result = await self._run_chapter()
        self.converter._attempt_segment_retry.assert_awaited_once_with(
            self.engine, 7, self.chapter.name, self.audio, config=self.config
        )
        self.assertFalse(self.wav.exists())
        self.assertEqual(self.audio.exists(), not strict)
        self.assertEqual(result.path, None if strict else self.audio)
        if strict:
            self.assertIn("Duration mismatch:", result.error)
            self.assertFalse(self.log.exists())
        else:
            self.assertIsNone(result.error)
            self._assert_log(False)

    async def test_invalid_duration_strict_uses_real_error_message(self):
        await self._invalid_duration(True)

    async def test_invalid_duration_non_strict_records_real_error_message(self):
        await self._invalid_duration(False)

    async def _recovered_retry(self, marker):
        self.marker = marker
        self.config.strict_validate = True

        async def recover(engine, index, title, path, *, config):
            self.assertIs(engine, self.engine)
            self.assertEqual((index, title, path), (7, self.chapter.name, self.audio))
            self.assertIs(config, self.config)
            self.assertEqual(self.audio.read_bytes()[:len(marker)], marker)
            self._write_audio(path, b"valid")
            return True

        self.converter._attempt_segment_retry.side_effect = recover
        result = await self._run_chapter()
        self.converter._attempt_segment_retry.assert_awaited_once()
        self.assertEqual(result.path, self.audio)
        self.assertIsNone(result.error)
        self.assertGreaterEqual(self.validator_probe.call_count, 3)
        self._assert_log(True)

    async def test_file_retry_revalidates_the_recovered_owned_output(self):
        await self._recovered_retry(b"invalid-file")

    async def test_duration_retry_revalidates_the_recovered_owned_output(self):
        await self._recovered_retry(b"invalid-duration")

    async def test_cancellation_during_retry_has_no_late_success_or_receipt(self):
        self.marker = b"invalid-file"
        entered = asyncio.Event()
        stopped = asyncio.Event()

        async def wait_in_retry(*args, **kwargs):
            entered.set()
            try:
                await asyncio.Event().wait()
            finally:
                stopped.set()

        self.converter._attempt_segment_retry.side_effect = wait_in_retry
        task = asyncio.create_task(self._run_chapter())
        try:
            await asyncio.wait_for(entered.wait(), timeout=2)
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
            self.assertTrue(stopped.is_set())
            self.assertTrue(task.cancelled())
            self.assertTrue(self.audio.exists(), "Cancellation preserves the existing owned output")
            self.assertFalse(self.wav.exists())
            self.assertFalse(self.log.exists())
            self.assertFalse((self.cache.cache_dir / "audio").exists())
            self.assertEqual(list(self.cache.cache_dir.rglob("*.mp3")), [])
            complete = self.converter.loc.t("status_complete")
            self.assertFalse(any(call.args[2] == complete for call in self.announcements.call_args_list))
        finally:
            if not task.done():
                task.cancel()
            await asyncio.gather(task, return_exceptions=True)

    async def test_cached_invalid_verbose_diagnostic_removes_cache_before_synthesis(self):
        self.config.force_reprocess = False
        self.converter.verbose = True
        self._write_audio(self.audio, b"invalid-duration")
        synthesize = self._synthesize

        async def assert_cache_removed(*args, **kwargs):
            self.assertFalse(self.audio.exists(), "Invalid cache must be unlinked before synthesis")
            return await synthesize(*args, **kwargs)

        self.engine.synthesize_async.side_effect = assert_cache_removed
        result = await self._run_chapter()
        self.engine.synthesize_async.assert_awaited_once()
        self.assertEqual(result.path, self.audio)
        self.assertIsNone(result.error)
        self.converter._attempt_segment_retry.assert_not_awaited()
        self._assert_log(True)
