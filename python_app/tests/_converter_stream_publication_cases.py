"""Stream publication scenarios sharing the original unittest fixture."""

from python_app.tests._converter_test_support import (
    Chapter as Chapter,
    MockTTSEngine as MockTTSEngine,
    Path as Path,
    json as json,
    patch as patch,
    re as re,
)

class StreamPublicationCases:
    async def test_stream_attempt_observations_preserve_cli_chunks_and_reject_late_callbacks(self):
        await self._verify_stream_attempt_observations(retry_first=False)

    async def test_stream_attempt_retry_replaces_cli_observation_identity(self):
        await self._verify_stream_attempt_observations(retry_first=True)

    async def test_stream_cache_callback_keeps_canonical_resume_bytes(self):
        await self._verify_stream_attempt_observations(retry_first=False, cached_callback=True)

    async def test_stream_manifest_failure_preserves_previous_publication(self):
        await self._verify_stream_attempt_observations(retry_first=False, manifest_failure=True)

    async def test_stream_job_manifest_urls_bind_publication_identity(self):
        await self._verify_stream_attempt_observations(retry_first=True, job_scoped=True)

    async def _verify_stream_attempt_observations(self, *, retry_first, cached_callback=False, manifest_failure=False, job_scoped=False):
        callbacks = []
        expected = {0: b"first audio" * 200, 1: b"second audio" * 200}
        failed_attempts = set()
        failed_publications = set()
        test_case = self

        class StreamingEngine(MockTTSEngine):
            async def synthesize_async(self, text, output_path, chunk_callback=None, resume_chunks_dir=None):
                output_path = Path(output_path)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                output_path.write_bytes(b"final audio" * 200)
                if chunk_callback:
                    callbacks.append((chunk_callback, output_path))
                    for index in (1, 0):
                        source = (Path(resume_chunks_dir) / f"chunk_{index:04d}.mp3" if cached_callback
                                  else output_path.with_name(f"source-{index}.mp3"))
                        source.write_bytes(expected[index])
                        chunk_callback(index, source, "Private fixture text")
                        if not cached_callback:
                            source.unlink()
                    if manifest_failure:
                        manifest_path = Path(resume_chunks_dir) / "manifest.json"
                        previous = manifest_path.read_bytes()
                        old_files = {path.name: path.read_bytes() for path in Path(resume_chunks_dir).glob("chunk_stream_*")}
                        source = output_path.with_name("replacement.mp3")
                        source.write_bytes(b"different replacement audio" * 200)
                        with patch("src.converter.atomic_write_manifest", side_effect=OSError("manifest failure")):
                            chunk_callback(0, source, "Replacement must not become visible")
                        source.unlink()
                        test_case.assertEqual(manifest_path.read_bytes(), previous)
                        test_case.assertEqual({path.name: path.read_bytes() for path in Path(resume_chunks_dir).glob("chunk_stream_*")}, old_files)
                    if retry_first and len(callbacks) == 1:
                        manifest = json.loads((Path(resume_chunks_dir) / "manifest.json").read_text())
                        failed_attempts.update(entry["observation"]["attemptId"] for entry in manifest["chunks"])
                        failed_publications.update(entry.get("id") for entry in manifest["chunks"])
                        output_path.unlink()
                        return None
                return output_path

        self.config.cache_dir = str(Path(self.temp_dir) / "cache")
        if job_scoped:
            self.config.job_id = "publication-fixture"
            self.config.output_dir = self.temp_dir
        result = await self.converter._convert_chapters_sequential(
            [Chapter(1, "Chapter", "chapter.html", "Content for a streaming fixture.")],
            StreamingEngine(), Path(self.temp_dir), self.config,
        )
        self.assertTrue(result.success)
        manifest_root = Path(self.temp_dir) if job_scoped else Path(self.config.cache_dir)
        manifests = list(manifest_root.rglob("manifest.json"))
        self.assertEqual(len(manifests), 1)
        manifest_path = manifests[0]
        manifest = json.loads(manifest_path.read_text())
        self.assertEqual([entry["index"] for entry in manifest["chunks"]], [0, 1])
        attempts = set()
        publications = set()
        for entry in manifest["chunks"]:
            publication_id = entry.get("id")
            self.assertIsInstance(publication_id, str)
            self.assertNotEqual(publication_id, str(entry["index"]))
            publications.add(publication_id)
            if job_scoped:
                self.assertEqual(entry["url"], f"/api/streams/publication-fixture/chapters/{manifest['chapterIndex']}/chunks/{publication_id}")
            self.assertEqual((manifest_path.parent / entry["file"]).read_bytes(), expected[entry["index"]])
            observation = entry["observation"]
            self.assertEqual(set(observation), {"version", "attemptId", "segmentReadyElapsedNanoseconds", "artifactPublishedElapsedNanoseconds"})
            self.assertGreaterEqual(observation["artifactPublishedElapsedNanoseconds"], observation["segmentReadyElapsedNanoseconds"])
            attempts.add(observation["attemptId"])
        self.assertEqual(len(attempts), 1)
        self.assertEqual(len(publications), 2)
        if cached_callback:
            canonical = [path for path in manifest_path.parent.glob("chunk_*.mp3")
                         if re.fullmatch(r"chunk_\d+\.mp3", path.name)]
            self.assertEqual(len(canonical), 2)
            self.assertEqual(b"".join(path.read_bytes() for path in sorted(canonical)), expected[0] + expected[1])
        if retry_first:
            self.assertTrue(failed_attempts)
            self.assertTrue(failed_attempts.isdisjoint(attempts))
            self.assertTrue(failed_publications.isdisjoint(publications))
        before = manifest_path.read_bytes()
        for callback, source in callbacks:
            callback(99, source, "Late obsolete callback")
        self.assertEqual(manifest_path.read_bytes(), before)
