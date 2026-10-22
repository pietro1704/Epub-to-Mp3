"""Automatic engine routing scenarios sharing the original unittest fixture."""

from python_app.tests._converter_test_support import (
    Chapter as Chapter,
    ConversionConfig as ConversionConfig,
    ConversionResult as ConversionResult,
    MockTTSEngine as MockTTSEngine,
    Path as Path,
    patch as patch,
)

class AutomaticEngineRoutingCases:
    async def test_auto_mode_selects_engine_per_chapter_during_conversion(self):
        """Auto mode should decide engine for each chapter during sequential conversion."""
        chapters = [
            Chapter(1, "Short Chapter", "short.html", "short text " * 20),
            Chapter(2, "Long Chapter", "long.html", "long text " * 4000),
        ]

        class RecordingEngine(MockTTSEngine):
            def __init__(self, label: str):
                super().__init__()
                self.label = label
                self.calls = 0

            async def synthesize_async(self, text, output_path, formatting_segments=None):
                self.calls += 1
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"fake audio" * 400)  # > 1000 bytes
                return output_path

        edge_engine = RecordingEngine("edge")
        kokoro_engine = RecordingEngine("kokoro")
        output_dir = Path(self.temp_dir)

        async def fake_convert_to_mp3(input_file, output_file, bitrate="8k"):
            output_path = Path(output_file)
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_bytes(b"mp3" * 400)
            return output_path

        self.converter.audio_processor.convert_to_mp3 = fake_convert_to_mp3

        auto_config = ConversionConfig(
            engine="auto",
            output_dir=str(output_dir),
            validate_audio=False,
            validate_text=False,
            book_title="Auto Book",
        )

        edge_cfg = ConversionConfig(
            engine="edge",
            output_dir=str(output_dir),
            validate_audio=False,
            validate_text=False,
            book_title="Auto Book",
        )
        kokoro_cfg = ConversionConfig(
            engine="kokoro",
            output_dir=str(output_dir),
            validate_audio=False,
            validate_text=False,
            book_title="Auto Book",
        )

        auto_pool = {
            "edge": (edge_cfg, edge_engine),
            "kokoro": (kokoro_cfg, kokoro_engine),
        }

        class DummyPool:
            def __init__(self, pool):
                self.pool = pool

            async def acquire(self, name):
                return self.pool[name]

            def release(self, *_args, **_kwargs):
                return None

            def register_engine(self, name, config, engine_obj=None):
                self.pool[name] = (config, engine_obj or self.pool[name][1])
                return None

        engine_pool = DummyPool(auto_pool)

        with patch.object(
            self.converter,
            "_pick_auto_engine",
            side_effect=[
                ("edge", ["edge", "kokoro"]),
                ("kokoro", ["kokoro", "edge"]),
            ],
        ) as mock_pick:
            with patch.object(self.converter, "_detect_short_audio_output", return_value=None):
                result = await self.converter._convert_chapters_sequential(
                    chapters,
                    engine_pool,
                    output_dir,
                    auto_config,
                    is_auto_engine=True,
                    auto_engine_pool=auto_pool,
                )

        self.assertTrue(result.success)
        self.assertEqual(result.converted_chapters, 2)
        self.assertEqual(mock_pick.call_count, 2)
        self.assertEqual(edge_engine.calls, 1)
        self.assertEqual(kokoro_engine.calls, 1)

    async def test_auto_mode_skips_edge_when_chapter_marked_with_connectivity_failure(self):
        """If chapter is marked as Edge-connectivity-failed, auto mode must not call Edge again."""
        chapters = [Chapter(1, "Retry Chapter", "retry.html", "retry text " * 600)]

        class RecordingEngine(MockTTSEngine):
            def __init__(self, label: str):
                super().__init__()
                self.label = label
                self.calls = 0

            async def synthesize_async(self, text, output_path, formatting_segments=None):
                self.calls += 1
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"fake audio" * 400)
                return output_path

        edge_engine = RecordingEngine("edge")
        kokoro_engine = RecordingEngine("kokoro")
        output_dir = Path(self.temp_dir)

        async def fake_convert_to_mp3(input_file, output_file, bitrate="8k"):
            output_path = Path(output_file)
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_bytes(b"mp3" * 400)
            return output_path

        self.converter.audio_processor.convert_to_mp3 = fake_convert_to_mp3

        auto_config = ConversionConfig(
            engine="auto",
            output_dir=str(output_dir),
            validate_audio=False,
            validate_text=False,
            book_title="Auto Retry Book",
        )
        auto_config.extra = {"edge_blocked_chapters": ["1"]}

        edge_cfg = ConversionConfig(
            engine="edge",
            output_dir=str(output_dir),
            validate_audio=False,
            validate_text=False,
            book_title="Auto Retry Book",
        )
        kokoro_cfg = ConversionConfig(
            engine="kokoro",
            output_dir=str(output_dir),
            validate_audio=False,
            validate_text=False,
            book_title="Auto Retry Book",
        )
        auto_pool = {
            "edge": (edge_cfg, edge_engine),
            "kokoro": (kokoro_cfg, kokoro_engine),
        }

        class DummyPool:
            def __init__(self, pool):
                self.pool = pool

            async def acquire(self, name):
                return self.pool[name]

            def release(self, *_args, **_kwargs):
                return None

            def register_engine(self, name, config, engine_obj=None):
                self.pool[name] = (config, engine_obj or self.pool[name][1])
                return None

        engine_pool = DummyPool(auto_pool)

        with patch.object(
            self.converter,
            "_pick_auto_engine",
            return_value=("edge", ["edge", "kokoro"]),
        ):
            with patch.object(self.converter, "_detect_short_audio_output", return_value=None):
                result = await self.converter._convert_chapters_sequential(
                    chapters,
                    engine_pool,
                    output_dir,
                    auto_config,
                    is_auto_engine=True,
                    auto_engine_pool=auto_pool,
                )

        self.assertTrue(result.success)
        self.assertEqual(result.converted_chapters, 1)
        self.assertEqual(edge_engine.calls, 0, "Edge must be skipped for blocked chapter")
        self.assertEqual(kokoro_engine.calls, 1)

    async def test_auto_mode_parallel_forwards_pool_per_chapter(self):
        """Parallel mode should invoke sequential worker with auto engine context."""
        chapters = [
            Chapter(1, "Chapter 1", "c1.html", "hello " * 400),
            Chapter(2, "Chapter 2", "c2.html", "world " * 500),
        ]
        output_dir = Path(self.temp_dir)
        auto_pool = {
            "edge": (ConversionConfig(engine="edge", output_dir=str(output_dir)), object()),
            "kokoro": (ConversionConfig(engine="kokoro", output_dir=str(output_dir)), object()),
        }
        config = ConversionConfig(
            engine="auto",
            output_dir=str(output_dir),
            validate_audio=False,
            validate_text=False,
            book_title="Parallel Auto",
        )
        calls = []

        class DummyPool:
            def update_parallel_slots(self, _slots):
                return None

        async def fake_convert_seq(
            chapters_arg,
            _engine_pool,
            _output_dir,
            _config,
            *,
            is_auto_engine=False,
            auto_engine_pool=None,
            skip_preprocessing=False,
            **_kwargs,
        ):
            chapter = chapters_arg[0]
            calls.append(
                {
                    "index": chapter.index,
                    "is_auto_engine": is_auto_engine,
                    "auto_pool_identity": auto_engine_pool is auto_pool,
                    "skip_preprocessing": skip_preprocessing,
                }
            )
            return ConversionResult(
                success=True,
                total_chapters=1,
                converted_chapters=1,
                output_files=[output_dir / f"{chapter.index:03d}.mp3"],
                errors=[],
            )

        with patch.object(
            self.converter, "_convert_chapters_sequential", side_effect=fake_convert_seq
        ):
            result = await self.converter._convert_chapters_parallel(
                chapters,
                DummyPool(),
                output_dir,
                config,
                max_concurrent_chapters=2,
                skip_preprocessing=True,
                is_auto_engine=True,
                auto_engine_pool=auto_pool,
            )

        self.assertTrue(result.success)
        self.assertEqual(result.converted_chapters, 2)
        self.assertEqual(len(calls), 2)
        self.assertTrue(all(entry["is_auto_engine"] for entry in calls))
        self.assertTrue(all(entry["auto_pool_identity"] for entry in calls))
        self.assertTrue(all(entry["skip_preprocessing"] for entry in calls))
        self.assertEqual(sorted(entry["index"] for entry in calls), [1, 2])
