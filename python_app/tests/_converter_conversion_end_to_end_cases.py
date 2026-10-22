"""Conversion end to end scenarios sharing the original unittest fixture."""

from python_app.tests._converter_test_support import (
    AsyncMock as AsyncMock,
    AudioConverter as AudioConverter,
    Chapter as Chapter,
    ConversionConfig as ConversionConfig,
    ConversionResult as ConversionResult,
    Mock as Mock,
    MockTTSEngine as MockTTSEngine,
    Path as Path,
    SimpleNamespace as SimpleNamespace,
    patch as patch,
    re as re,
)

class ConversionEndToEndCases:
    async def test_convert_integration(self):
        """Test full convert method integration"""
        with (
            patch.object(self.converter, "_setup_output_directory") as mock_setup,
            patch.object(self.converter.tts_factory, "create_engine") as mock_create,
            patch.object(self.converter, "_convert_chapters_sequential") as mock_convert_seq,
            patch.object(self.converter, "_convert_chapters_parallel") as mock_convert_parallel,
            patch.object(self.converter, "_report_results") as mock_report,
        ):
            mock_setup.return_value = Path(self.temp_dir)
            mock_engine = Mock()
            # Configure Protocol methods for validation system
            mock_engine.get_synthesis_tracker = Mock(return_value=None)
            mock_engine.get_synthesis_log = Mock(return_value=[])
            mock_create.return_value = mock_engine
            expected_result = ConversionResult(
                success=True,
                total_chapters=2,
                converted_chapters=2,
                output_files=[],
                errors=[],
            )
            mock_convert_seq.return_value = expected_result
            mock_convert_parallel.return_value = expected_result

            result = await self.converter.convert(self.mock_reader, self.config)

            self.assertIs(result, expected_result)
            self.assertGreaterEqual(mock_setup.call_count, 1)
            mock_create.assert_called_once()
            self.assertTrue(
                mock_convert_seq.called or mock_convert_parallel.called,
                "expected sequential or parallel conversion to be called",
            )
            mock_report.assert_called_once_with(expected_result)

    async def test_convert_rejects_an_empty_parser_result(self):
        """A parser returning no chapters must fail rather than report success."""
        empty_reader = SimpleNamespace(
            title="Empty PDF",
            author="",
            file_path=Path(self.temp_dir) / "empty.pdf",
            get_chapter_structure=lambda preserve_all=True: [],
        )

        with patch.object(self.converter, "_report_results", new_callable=AsyncMock) as report:
            result = await self.converter.convert(empty_reader, self.config)

        self.assertFalse(result.success)
        self.assertEqual(result.total_chapters, 0)
        self.assertEqual(result.converted_chapters, 0)
        self.assertEqual(result.errors, ["No readable chapters were extracted from Empty PDF"])
        report.assert_awaited_once_with(result)

    async def test_convert_auto_e2e_edge_dns_failure_falls_back_offline(self):
        """E2E: auto mode should recover from Edge DNS failure by switching offline."""
        chapter_text = "conteudo de teste " * 600
        chapter = Chapter(1, "Chapter DNS", "dns.html", chapter_text, speech_text=chapter_text)
        reader = SimpleNamespace(
            title="E2E DNS Book",
            author="Tester",
            file_path=Path(self.temp_dir) / "e2e_dns.epub",
            get_chapter_structure=lambda preserve_all=True: [chapter],
        )

        class EdgeDnsEngine(MockTTSEngine):
            def __init__(self):
                super().__init__()
                self.calls = 0

            async def synthesize_async(self, text, output_path, formatting_segments=None):
                self.calls += 1
                self.last_error = "ClientConnectorDNSError: dns failure"
                return None

        class PiperOkEngine(MockTTSEngine):
            def __init__(self):
                super().__init__()
                self.calls = 0

            async def synthesize_async(self, text, output_path, formatting_segments=None):
                self.calls += 1
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"wav" * 500)
                return output_path

        edge_engine = EdgeDnsEngine()
        piper_engine = PiperOkEngine()

        async def fake_convert_to_mp3(input_file, output_file, bitrate="8k"):
            output_path = Path(output_file)
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_bytes(b"mp3" * 350_000)
            return output_path

        self.converter.audio_processor.convert_to_mp3 = fake_convert_to_mp3

        auto_config = ConversionConfig(
            engine="auto",
            output_dir=self.temp_dir,
            validate_audio=False,
            validate_text=False,
            auto_validate_output=False,
            auto_fix_output=False,
            book_title="E2E DNS Book",
            force_reprocess=True,
        )
        edge_cfg = ConversionConfig(
            engine="edge",
            output_dir=self.temp_dir,
            validate_audio=False,
            validate_text=False,
            auto_validate_output=False,
            auto_fix_output=False,
            book_title="E2E DNS Book",
        )
        piper_cfg = ConversionConfig(
            engine="piper",
            output_dir=self.temp_dir,
            validate_audio=False,
            validate_text=False,
            auto_validate_output=False,
            auto_fix_output=False,
            book_title="E2E DNS Book",
        )

        with patch.object(
            self.converter,
            "_prepare_auto_engines",
            return_value={"edge": (edge_cfg, edge_engine), "piper": (piper_cfg, piper_engine)},
        ):
            with patch.object(
                self.converter,
                "_pick_auto_engine",
                return_value=("edge", ["edge", "piper"]),
            ):
                result = await self.converter.convert(reader, auto_config)

        self.assertTrue(result.success)
        self.assertGreaterEqual(result.converted_chapters, 1)
        self.assertGreaterEqual(edge_engine.calls, 1)
        self.assertGreaterEqual(piper_engine.calls, 1)
        blocked = (auto_config.extra or {}).get("edge_blocked_chapters", [])
        self.assertTrue(blocked, "Edge blocked chapter list should be persisted after DNS failure")

    async def test_convert_auto_resume_and_adaptive_checkpoint_e2e(self):
        """E2E: auto mode should save checkpoint on partial failure and resume only failed chapter."""
        chapter_ok = Chapter(1, "Chapter 1", "c1.html", "texto ok " * 400)
        chapter_fail = Chapter(2, "Chapter 2", "c2.html", "FORCE_FAIL " * 400)
        reader = SimpleNamespace(
            title="Resume Book",
            author="Tester",
            file_path=Path(self.temp_dir) / "resume.epub",
            get_chapter_structure=lambda preserve_all=True: [chapter_ok, chapter_fail],
        )

        class FlakyPiperEngine(MockTTSEngine):
            def __init__(self):
                super().__init__()
                self.calls = 0

            async def synthesize_async(self, text, output_path, formatting_segments=None):
                self.calls += 1
                if "chapter 2" in str(output_path).lower() or "002" in str(output_path):
                    self.last_error = "timeout while generating audio"
                    return None
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"wav" * 500)
                return output_path

        class HealthyPiperEngine(MockTTSEngine):
            def __init__(self):
                super().__init__()
                self.calls = 0

            async def synthesize_async(self, text, output_path, formatting_segments=None):
                self.calls += 1
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"wav" * 500)
                return output_path

        async def fake_convert_to_mp3(input_file, output_file, bitrate="8k"):
            output_path = Path(output_file)
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_bytes(b"mp3" * 250_000)
            return output_path

        self.converter.audio_processor.convert_to_mp3 = fake_convert_to_mp3
        config_first = ConversionConfig(
            engine="auto",
            output_dir=self.temp_dir,
            cache_dir=Path(self.temp_dir) / "cache",
            validate_audio=False,
            validate_text=False,
            auto_validate_output=False,
            auto_fix_output=False,
            book_title="Resume Book",
            force_reprocess=True,
            extra={"max_auto_retries": "0", "manual_retry_failed": "0"},
        )
        flaky_engine = FlakyPiperEngine()
        piper_cfg = ConversionConfig(
            engine="piper",
            output_dir=self.temp_dir,
            cache_dir=Path(self.temp_dir) / "cache",
            validate_audio=False,
            validate_text=False,
            auto_validate_output=False,
            auto_fix_output=False,
            book_title="Resume Book",
        )
        with patch.object(
            self.converter,
            "_prepare_auto_engines",
            return_value={"piper": (piper_cfg, flaky_engine)},
        ):
            result_first = await self.converter.convert(reader, config_first)

        self.assertIsNotNone(result_first)
        cache_dir = Path(config_first.cache_dir)
        self.assertTrue((cache_dir / "_adaptive_state_checkpoint.json").exists())
        self.converter._save_failure_checkpoint(
            cache_dir,
            failed_chapters=["2"],
            edge_blocked_chapters=[],
        )
        self.assertTrue((cache_dir / "_failure_checkpoint.json").exists())

        second_converter = AudioConverter()
        second_converter.audio_processor.convert_to_mp3 = fake_convert_to_mp3
        healthy_engine = HealthyPiperEngine()
        config_second = ConversionConfig(
            engine="auto",
            output_dir=self.temp_dir,
            cache_dir=Path(self.temp_dir) / "cache",
            validate_audio=False,
            validate_text=False,
            auto_validate_output=False,
            auto_fix_output=False,
            book_title="Resume Book",
            force_reprocess=True,
            extra={"resume_from_failure": "1"},
        )
        piper_cfg_second = ConversionConfig(
            engine="piper",
            output_dir=self.temp_dir,
            cache_dir=Path(self.temp_dir) / "cache",
            validate_audio=False,
            validate_text=False,
            auto_validate_output=False,
            auto_fix_output=False,
            book_title="Resume Book",
        )
        with patch.object(
            second_converter,
            "_prepare_auto_engines",
            return_value={"piper": (piper_cfg_second, healthy_engine)},
        ):
            result_second = await second_converter.convert(reader, config_second)

        self.assertTrue(result_second.success)
        self.assertIn(
            healthy_engine.calls,
            {1, 2, 3},
            "Resume flow should stay bounded to the failed chapter; warmup/probes may add extra calls",
        )
        self.assertEqual(second_converter._load_failure_checkpoint(cache_dir), {})

    async def test_convert_with_exception(self):
        """Test convert method propagates exceptions"""

        with patch.object(self.converter.tts_factory, "create_engine") as mock_create:
            mock_create.side_effect = Exception("Test error")

            with self.assertRaises(Exception):
                await self.converter.convert(self.mock_reader, self.config)

    async def test_show_structure_matches_tts_input(self):
        """Verify that show-structure output matches what actually goes to TTS."""
        cache_dir = Path(self.temp_dir) / ".cache" / "Structure_Test"
        cache_dir.mkdir(parents=True, exist_ok=True)

        # Chapter with language tags (as shown in show-structure)
        chapter_with_tags = Chapter(
            index=1,
            name="Structure Test",
            source_path="ch1.html",
            text="Original parsed text",
            speech_text="English text [[lang:pt-BR]]Texto português[[/lang]] more English",
        )

        # Track what TTS receives
        tts_inputs = []

        class CapturingTTSEngine:
            async def synthesize_async(self, text, output_path, formatting_segments=None):
                tts_inputs.append(text)
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"audio" * 500)
                return output_path

        engine = CapturingTTSEngine()
        config = ConversionConfig(
            engine="edge",
            output_dir=str(cache_dir),
            validate_audio=False,
            validate_text=False,
            book_title="Structure_Test",
        )

        # Run conversion
        result = await self.converter._convert_chapters_sequential(
            [chapter_with_tags], engine, cache_dir, config
        )

        self.assertEqual(result.converted_chapters, 1)

        # What was sent to TTS
        tts_input = " ".join(tts_inputs)

        # What would be shown in show-structure (the speech_text)
        show_structure_text = chapter_with_tags.speech_text

        # They MUST match
        import re

        normalize = lambda t: re.sub(r"\s+", " ", t or "").strip()

        self.assertEqual(
            normalize(tts_input),
            normalize(show_structure_text),
            "CRITICAL: show-structure output does NOT match TTS input! "
            "This means the text files don't reflect what was actually converted.",
        )

        # Verify pre-tts.txt file matches as well
        text_dir = cache_dir / "text"
        pre_tts_files = list(text_dir.glob("*-pre-tts.txt"))
        self.assertEqual(len(pre_tts_files), 1)

        cached_text = pre_tts_files[0].read_text(encoding="utf-8")

        self.assertEqual(
            normalize(cached_text),
            normalize(show_structure_text),
            "pre-tts.txt should match show-structure (speech_text)",
        )
