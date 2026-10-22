"""Artifact integrity cases inherited by the original unittest test classes."""

import tempfile
from pathlib import Path

import validate_conversion as vc


class FixOutputFilenamesCases:
    def test_renames_html_in_mp3_name(self):
        with tempfile.TemporaryDirectory() as output_dir:
            output_path = Path(output_dir)
            bad = output_path / "1 - Chapter &amp; One.mp3"
            bad.write_bytes(b"audio")

            renamed = vc.fix_output_filenames(output_path)

            self.assertEqual(len(renamed), 1)
            self.assertFalse(bad.exists())
            good = output_path / "1 - Chapter & One.mp3"
            self.assertTrue(good.exists())

    def test_renames_html_entities_in_text_files(self):
        with tempfile.TemporaryDirectory() as output_dir:
            output_path = Path(output_dir)
            text_dir = output_path / "text"
            text_dir.mkdir()
            bad = text_dir / "1 - Chapter &amp; Two-parsed.txt"
            bad.write_text("content")

            renamed = vc.fix_output_filenames(output_path)

            self.assertEqual(len(renamed), 1)
            self.assertFalse(bad.exists())
            good = text_dir / "1 - Chapter & Two-parsed.txt"
            self.assertTrue(good.exists())

    def test_renames_in_cache_dir(self):
        with (
            tempfile.TemporaryDirectory() as output_dir,
            tempfile.TemporaryDirectory() as cache_dir,
        ):
            output_path = Path(output_dir)
            cache_text = Path(cache_dir) / "text"
            cache_text.mkdir()
            bad = cache_text / "1 - Chapter &amp; One-parsed.txt"
            bad.write_text("content")

            renamed = vc.fix_output_filenames(output_path, cache_dir=Path(cache_dir))

            self.assertEqual(len(renamed), 1)
            self.assertFalse(bad.exists())

    def test_clean_names_untouched(self):
        with tempfile.TemporaryDirectory() as output_dir:
            output_path = Path(output_dir)
            good = output_path / "1 - Normal Chapter.mp3"
            good.write_bytes(b"audio")

            renamed = vc.fix_output_filenames(output_path)

            self.assertEqual(len(renamed), 0)
            self.assertTrue(good.exists())


class VerifyChapterNamesCases:
    """Tests for validate_conversion.verify_chapter_names."""

    def _mp3(self, tmp_dir: Path, name: str) -> Path:
        p = tmp_dir / name
        p.write_bytes(b"\xff\xfb" + b"\x00" * 16)
        return p

    def test_clean_names_no_issues(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            self._mp3(out, "1 - Chapter One.mp3")
            issues = vc.verify_chapter_names([(1, "Chapter One", "text")], out)
            self.assertEqual(issues, [])

    def test_html_tag_in_name_reported(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            issues = vc.verify_chapter_names([(1, "<p>Chapter One</p>", "text")], Path(d))
            self.assertTrue(any("HTML tags" in i for i in issues))

    def test_html_entity_in_name_reported(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            issues = vc.verify_chapter_names([(1, "Chapter &amp; One", "text")], Path(d))
            self.assertTrue(any("HTML entities" in i for i in issues))

    def test_nbsp_in_name_reported(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            issues = vc.verify_chapter_names([(1, "Chapter\xa0One", "text")], Path(d))
            self.assertTrue(any("non-breaking" in i for i in issues))

    def test_number_only_name_reported(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            issues = vc.verify_chapter_names([(1, "42", "text")], Path(d))
            self.assertTrue(any("no descriptive title" in i for i in issues))

    def test_number_only_with_part_prefix_reported(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            issues = vc.verify_chapter_names([(1, "part001 - 3", "text")], Path(d))
            self.assertTrue(any("no descriptive title" in i for i in issues))

    def test_descriptive_name_not_flagged(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            issues = vc.verify_chapter_names([(1, "Chapter 1: The Beginning", "text")], Path(d))
            self.assertFalse(any("no descriptive title" in i for i in issues))

    def test_empty_name_skipped(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            issues = vc.verify_chapter_names([(1, "", "text")], Path(d))
            self.assertEqual(issues, [])

    def test_mp3_with_html_entity_in_filename_reported(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            bad = out / "1 - Chapter &amp; One.mp3"
            bad.write_bytes(b"\xff\xfb" + b"\x00" * 16)
            issues = vc.verify_chapter_names([], out)
            self.assertTrue(any("MP3 filename" in i and "artefact" in i for i in issues))

    def test_mp3_with_clean_filename_not_flagged(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            self._mp3(out, "1 - Normal Name.mp3")
            issues = vc.verify_chapter_names([], out)
            self.assertEqual(issues, [])

    def test_multiple_issues_all_reported(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            issues = vc.verify_chapter_names(
                [
                    (1, "<h1>Title</h1>", "t"),
                    (2, "Chapter &eacute;", "t"),
                    (3, "99", "t"),
                ],
                Path(d),
            )
            self.assertGreaterEqual(len(issues), 3)


class VerifyMp3IntegrityCases:
    """Tests for validate_conversion.verify_mp3_integrity."""

    def test_valid_mp3_sync_header_passes(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            mp3 = Path(d) / "1 - Track.mp3"
            mp3.write_bytes(b"\xff\xfb" + b"\x00" * 4096)
            self.assertEqual(vc.verify_mp3_integrity(Path(d)), [])

    def test_id3_header_passes(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            mp3 = Path(d) / "1 - Track.mp3"
            mp3.write_bytes(b"ID3" + b"\x04\x00" + b"\x00" * 4096)
            self.assertEqual(vc.verify_mp3_integrity(Path(d)), [])

    def test_invalid_header_reported(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            mp3 = Path(d) / "1 - Bad.mp3"
            mp3.write_bytes(b"fakefakefake" * 100)
            issues = vc.verify_mp3_integrity(Path(d))
            self.assertEqual(len(issues), 1)
            self.assertIn("unexpected header", issues[0])
            self.assertIn("1 - Bad.mp3", issues[0])

    def test_too_small_file_reported(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            mp3 = Path(d) / "1 - Tiny.mp3"
            mp3.write_bytes(b"\xff\xfb" + b"\x00" * 10)
            issues = vc.verify_mp3_integrity(Path(d), min_size_bytes=100)
            self.assertEqual(len(issues), 1)
            self.assertIn("small", issues[0])

    def test_empty_directory_no_issues(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(vc.verify_mp3_integrity(Path(d)), [])

    def test_multiple_valid_files_all_pass(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            for i in range(1, 4):
                mp3 = Path(d) / f"{i} - Track {i}.mp3"
                mp3.write_bytes(b"\xff\xfb" + b"\x00" * 4096)
            self.assertEqual(vc.verify_mp3_integrity(Path(d)), [])

    def test_mix_valid_invalid_reports_invalid_only(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            good = Path(d) / "1 - Good.mp3"
            good.write_bytes(b"\xff\xfb" + b"\x00" * 4096)
            bad = Path(d) / "2 - Bad.mp3"
            bad.write_bytes(b"notanmp3" * 100)
            issues = vc.verify_mp3_integrity(Path(d))
            self.assertEqual(len(issues), 1)
            self.assertIn("2 - Bad.mp3", issues[0])

    def test_alternate_sync_headers_pass(self) -> None:
        for header in (b"\xff\xfa", b"\xff\xf3", b"\xff\xf2", b"\xff\xe3"):
            with tempfile.TemporaryDirectory() as d:
                mp3 = Path(d) / "1 - Track.mp3"
                mp3.write_bytes(header + b"\x00" * 4096)
                issues = vc.verify_mp3_integrity(Path(d))
                self.assertEqual(issues, [], f"Header {header!r} should pass")

    def test_non_mp3_files_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            txt = Path(d) / "notes.txt"
            txt.write_text("not an mp3")
            self.assertEqual(vc.verify_mp3_integrity(Path(d)), [])
