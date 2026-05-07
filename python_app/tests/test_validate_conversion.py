# -*- coding: utf-8 -*-
import os
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import validate_conversion as vc


class TestValidateConversionHelpers(unittest.TestCase):
    def test_normalize_title_handles_punctuation(self):
        title = "5.7 - Derry: Segundo interlúdio — “teste”_extra"
        normalized = vc.normalize_title(title)
        self.assertIn("derry segundo interludio", normalized)
        self.assertNotIn(":", normalized)
        self.assertNotIn("_", normalized)

    def test_find_cache_dir_skips_empty_filename_candidate(self):
        """Regression for batch validation skip (2026-05-07).

        The same EPUB can produce two cache directories — one keyed by the
        raw filename stem (sometimes left empty after promotion) and one
        keyed by the resolved title. ``find_cache_dir`` must scan every
        candidate and skip directories without a populated ``text/`` subdir.
        """
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            cache_root = tmp_path / ".cache"
            cache_root.mkdir()
            empty = cache_root / "A Divina Comédia (Z-Library)"
            empty.mkdir()
            populated = cache_root / "La Divina Commedia _ A Divina Comédia"
            (populated / "edge" / "text").mkdir(parents=True)
            (populated / "edge" / "text" / "1.txt").write_text("hello")

            cwd = os.getcwd()
            os.chdir(tmp_path)
            try:
                book = Path("/some/dir/A Divina Comédia (Z-Library).epub")
                resolved = vc.find_cache_dir(book)
                self.assertEqual(
                    resolved,
                    Path(".cache/La Divina Commedia _ A Divina Comédia/edge"),
                )
            finally:
                os.chdir(cwd)

    def test_find_cache_dir_uses_epub_metadata_title(self):
        """Filename and EPUB title often diverge (Project Gutenberg files).

        ``find_cache_dir`` should fall back to the EPUB's metadata title
        when filename tokens don't overlap with any cache directory.
        Example: filename ``pg50936-images-3.epub`` → title
        ``Man in a Sewing Machine`` → cache keyed by title.
        """
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            cache_root = tmp_path / ".cache"
            populated = cache_root / "Man in a Sewing Machine"
            (populated / "text").mkdir(parents=True)
            (populated / "text" / "1.txt").write_text("hello")

            cwd = os.getcwd()
            os.chdir(tmp_path)
            try:
                # Stub EbookReader to return the metadata title we expect.
                import python_app.src.ebook_reader as reader_mod

                class _StubReader:
                    title = "Man in a Sewing Machine"

                    def __init__(self, _path):
                        pass

                with patch.object(reader_mod, "EbookReader", _StubReader):
                    book = Path("/some/dir/pg50936-images-3.epub")
                    resolved = vc.find_cache_dir(book)
                    self.assertEqual(resolved, Path(".cache/Man in a Sewing Machine"))
            finally:
                os.chdir(cwd)

    def test_find_cache_dir_accepts_txt_variant(self):
        """Cache populated by --show-structure uses ``txt/`` not ``text/``.

        ``find_cache_dir`` must accept either layout so validation works
        regardless of which CLI path populated the cache.
        """
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            cache_root = tmp_path / ".cache"
            (cache_root / "Voo Noturno").mkdir(parents=True)
            (cache_root / "Voo Noturno" / "txt").mkdir()
            (cache_root / "Voo Noturno" / "txt" / "1.txt").write_text("hello")

            cwd = os.getcwd()
            os.chdir(tmp_path)
            try:
                book = Path("/some/dir/Voo Noturno - Antoine de Saint-Exupery.epub")
                resolved = vc.find_cache_dir(book)
                # Should land on the cache dir; the txt → text symlink is
                # created so downstream code can find ``text/``.
                self.assertTrue((resolved / "text").exists())
            finally:
                os.chdir(cwd)

    def test_normalize_title_key_survives_long_hierarchical_prefix(self):
        """Regression for Piranesi false-positive (2026-05-07).

        A long hierarchical prefix like ``9.11 - Parte 7: Matthew Rose Sorensen
        - ...`` used to push the EPUB title past the 80-char limit, breaking
        substring match in validate_book and producing spurious
        ``Missing cache files`` alerts.
        """
        epub_title = "Valentine Ketterley desapareceu ENTRADA PARA O"
        conv_title = (
            "9.11 - Parte 7: Matthew Rose Sorensen - "
            "Valentine Ketterley desapareceu ENTRADA PARA O - DIA 26 DE NOVEMBRO"
        )
        epub_norm = vc.normalize_title_key(epub_title)
        conv_norm = vc.normalize_title_key(conv_title)
        self.assertTrue(
            epub_norm in conv_norm or conv_norm in epub_norm,
            f"title match broken by truncation:\n  epub={epub_norm!r}\n  conv={conv_norm!r}",
        )

    def test_build_cache_index_prefers_first_dir(self):
        with (
            tempfile.TemporaryDirectory() as first_dir,
            tempfile.TemporaryDirectory() as second_dir,
        ):
            first_text = Path(first_dir) / "text"
            second_text = Path(second_dir) / "text"
            first_text.mkdir()
            second_text.mkdir()

            first_file = first_text / "1 - Capitulo-parsed.txt"
            second_file = second_text / "1 - Capitulo-parsed.txt"
            first_file.write_text("primeiro", encoding="utf-8")
            second_file.write_text("segundo", encoding="utf-8")

            index = vc.build_cache_index([first_text, second_text])
            key = vc.normalize_title("Capitulo")
            self.assertEqual(index[key]["parsed"], first_file)


class TestValidateBook(unittest.TestCase):
    def test_validate_book_uses_output_text_and_mp3_match(self):
        with (
            tempfile.TemporaryDirectory() as output_dir,
            tempfile.TemporaryDirectory() as cache_dir,
        ):
            output_path = Path(output_dir)
            cache_path = Path(cache_dir)
            text_dir = output_path / "text"
            text_dir.mkdir()

            chapter_title = "5.7 - Derry: Segundo interlúdio"
            parsed_path = text_dir / "1 - Derry_ Segundo interlúdio-parsed.txt"
            pretts_path = text_dir / "1 - Derry_ Segundo interlúdio-pre-tts.txt"
            parsed_path.write_text("texto base do capitulo", encoding="utf-8")
            pretts_path.write_text("texto base do capitulo", encoding="utf-8")

            mp3_path = output_path / "1 - Derry_ Segundo interlúdio.mp3"
            # Valid MP3 sync header so verify_mp3_integrity passes
            mp3_path.write_bytes(b"\xff\xfb" + b"\x00" * 4096)

            # Create complete book text file (expected by validation)
            full_book_path = output_path / "book_completo.txt"
            full_book_path.write_text("texto base do capitulo", encoding="utf-8")

            fake_result = SimpleNamespace(is_valid=True, duration_diff_percent=0)

            with patch("validate_conversion.AudioValidator") as mock_validator:
                mock_validator.return_value.validate_duration.return_value = fake_result
                with patch(
                    "validate_conversion.load_epub_chapters",
                    return_value=[(1, chapter_title, "texto base do capitulo")],
                ):
                    stats, issues = vc.validate_book(
                        Path("book.epub"),
                        output_dir=output_path,
                        cache_dir=cache_path,
                    )

            self.assertEqual(stats["missing_cache"], 0)
            self.assertEqual(stats["missing_mp3"], 0)
            self.assertEqual(issues, [])

    def test_validate_book_rejects_mismatched_names_and_html(self):
        with (
            tempfile.TemporaryDirectory() as output_dir,
            tempfile.TemporaryDirectory() as cache_dir,
        ):
            output_path = Path(output_dir)
            text_dir = output_path / "text"
            text_dir.mkdir()

            parsed_path = text_dir / "1 - Outro titulo-parsed.txt"
            pretts_path = text_dir / "1 - Outro titulo-pre-tts.txt"
            html_text = "<p>Capítulo 1 - Raiz</p> Começo limpo e sem lixo."
            parsed_path.write_text(html_text, encoding="utf-8")
            pretts_path.write_text(html_text, encoding="utf-8")

            mp3_path = output_path / "1 - Nome Errado.mp3"
            mp3_path.write_bytes(b"fake mp3 data" * 200)

            fake_result = SimpleNamespace(is_valid=True, duration_diff_percent=0)

            with patch("validate_conversion.AudioValidator") as mock_validator:
                mock_validator.return_value.validate_duration.return_value = fake_result
                with patch(
                    "validate_conversion.load_epub_chapters",
                    return_value=[(1, "Capítulo 1 - Raiz", "Capítulo 1 - Raiz começa aqui.")],
                ):
                    stats, issues = vc.validate_book(
                        Path("book.epub"),
                        output_dir=output_path,
                        cache_dir=Path(cache_dir),
                    )

            self.assertGreater(stats["text_mismatch"], 0)
            self.assertTrue(
                any("HTML" in issue or "tag" in issue.lower() for issue in issues),
                "HTML tags in cached text should be reported",
            )
            self.assertTrue(
                any("filename" in issue.lower() or "nome" in issue.lower() for issue in issues),
                "Mismatched TXT/MP3 names should be reported",
            )

    def test_validate_book_flags_even_small_truncation(self):
        with (
            tempfile.TemporaryDirectory() as output_dir,
            tempfile.TemporaryDirectory() as cache_dir,
        ):
            output_path = Path(output_dir)
            text_dir = output_path / "text"
            text_dir.mkdir()

            original_text = "Capítulo 2 - Trecho original com final completo."
            truncated_text = "Capítulo 2 - Trecho original com final complet"

            parsed_path = text_dir / "1 - Capítulo 2 - Trecho original-parsed.txt"
            pretts_path = text_dir / "1 - Capítulo 2 - Trecho original-pre-tts.txt"
            parsed_path.write_text(truncated_text, encoding="utf-8")
            pretts_path.write_text(truncated_text, encoding="utf-8")

            mp3_path = output_path / "1 - Capítulo 2 - Trecho original.mp3"
            mp3_path.write_bytes(b"fake mp3 data" * 200)

            fake_result = SimpleNamespace(is_valid=True, duration_diff_percent=0)

            with patch("validate_conversion.AudioValidator") as mock_validator:
                mock_validator.return_value.validate_duration.return_value = fake_result
                with patch(
                    "validate_conversion.load_epub_chapters",
                    return_value=[(1, "Capítulo 2 - Trecho original", original_text)],
                ):
                    stats, issues = vc.validate_book(
                        Path("book.epub"),
                        output_dir=output_path,
                        cache_dir=Path(cache_dir),
                    )

            self.assertEqual(stats["text_mismatch"], 1)
            self.assertTrue(
                any("difer" in issue.lower() or "trunc" in issue.lower() for issue in issues),
                "Even small text truncations must be reported as issues",
            )

    def test_validate_book_detects_duplicate_outputs(self):
        with (
            tempfile.TemporaryDirectory() as output_dir,
            tempfile.TemporaryDirectory() as cache_dir,
        ):
            output_path = Path(output_dir)
            text_dir = output_path / "text"
            text_dir.mkdir()

            duplicate_text = "Capítulo único renderizado duas vezes."

            for idx in (1, 2):
                parsed = text_dir / f"{idx} - Capítulo {idx}-parsed.txt"
                pretts = text_dir / f"{idx} - Capítulo {idx}-pre-tts.txt"
                parsed.write_text(duplicate_text, encoding="utf-8")
                pretts.write_text(duplicate_text, encoding="utf-8")
                mp3 = output_path / f"{idx} - Capítulo {idx}.mp3"
                mp3.write_bytes(b"fake mp3 data" * 200)

            fake_result = SimpleNamespace(is_valid=True, duration_diff_percent=0)

            with patch("validate_conversion.AudioValidator") as mock_validator:
                mock_validator.return_value.validate_duration.return_value = fake_result
                with patch(
                    "validate_conversion.load_epub_chapters",
                    return_value=[
                        (1, "Capítulo 1", duplicate_text),
                        (2, "Capítulo 2", "Conteúdo diferente que foi sobrescrito."),
                    ],
                ):
                    stats, issues = vc.validate_book(
                        Path("book.epub"),
                        output_dir=output_path,
                        cache_dir=Path(cache_dir),
                    )

            self.assertGreaterEqual(stats["text_mismatch"], 1)
            self.assertTrue(
                any("duplicate" in issue.lower() for issue in issues),
                "Duplicate chapter outputs should be reported as critical issues",
            )

    def test_validate_book_detects_duplicate_audio(self):
        with (
            tempfile.TemporaryDirectory() as output_dir,
            tempfile.TemporaryDirectory() as cache_dir,
        ):
            output_path = Path(output_dir)
            text_dir = output_path / "text"
            text_dir.mkdir()

            chapter_text_a = "A" * 500
            chapter_text_b = "B" * 500

            for idx, payload in ((1, chapter_text_a), (2, chapter_text_b)):
                parsed = text_dir / f"{idx} - Capítulo {idx}-parsed.txt"
                pretts = text_dir / f"{idx} - Capítulo {idx}-pre-tts.txt"
                parsed.write_text(payload, encoding="utf-8")
                pretts.write_text(payload, encoding="utf-8")
                mp3 = output_path / f"{idx} - Capítulo {idx}.mp3"
                mp3.write_bytes(b"same-audio" * 200)

            fake_result = SimpleNamespace(is_valid=True, duration_diff_percent=0)

            with patch("validate_conversion.AudioValidator") as mock_validator:
                mock_validator.return_value.validate_duration.return_value = fake_result
                with patch(
                    "validate_conversion.load_epub_chapters",
                    return_value=[
                        (1, "Capítulo 1", chapter_text_a),
                        (2, "Capítulo 2", chapter_text_b),
                    ],
                ):
                    stats, issues = vc.validate_book(
                        Path("book.epub"),
                        output_dir=output_path,
                        cache_dir=Path(cache_dir),
                    )

            self.assertGreaterEqual(stats["audio_duplicate"], 1)
            self.assertTrue(
                any(
                    "duplicate audio" in issue.lower() or "audio" in issue.lower()
                    for issue in issues
                ),
                "Duplicate audio should be reported as critical issues",
            )

    def test_detect_duplicate_audio_files(self):
        with tempfile.TemporaryDirectory() as output_dir:
            output_path = Path(output_dir)
            first = output_path / "1 - Capitulo 1.mp3"
            second = output_path / "2 - Capitulo 2.mp3"
            third = output_path / "3 - Capitulo 3.mp3"

            payload = b"same-audio" * 200
            first.write_bytes(payload)
            second.write_bytes(payload)
            third.write_bytes(b"unique-audio" * 200)

            groups = vc.detect_duplicate_audio_files(output_path)

            self.assertEqual(len(groups), 1)
            names = sorted(p.name for p in groups[0])
            self.assertEqual(names, sorted([first.name, second.name]))


class TestFixOutputFilenames(unittest.TestCase):
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


class TestComplotoSizeMismatchStat(unittest.TestCase):
    def test_completo_size_mismatch_counted_in_stats(self):
        """completo_size_mismatch must be > 0 when file content differs from EPUB by > 5%."""
        with (
            tempfile.TemporaryDirectory() as output_dir,
            tempfile.TemporaryDirectory() as cache_dir,
        ):
            output_path = Path(output_dir)
            text_dir = output_path / "text"
            text_dir.mkdir()

            chapter_text = "A" * 1000
            parsed = text_dir / "1 - Chapter1-parsed.txt"
            pretts = text_dir / "1 - Chapter1-pre-tts.txt"
            parsed.write_text(chapter_text)
            pretts.write_text(chapter_text)

            mp3 = output_path / "1 - Chapter1.mp3"
            mp3.write_bytes(b"\xff\xfb" + b"\x00" * 4096)

            # Write completo.txt with only ~10% of the expected content
            completo = output_path / "book_completo.txt"
            completo.write_text("CHAPTER 1: Chapter1\n\n" + "A" * 50)

            with patch(
                "validate_conversion.load_epub_chapters",
                return_value=[(1, "Chapter1", chapter_text)],
            ):
                stats, issues = vc.validate_book(
                    Path("book.epub"),
                    output_dir=output_path,
                    cache_dir=Path(cache_dir),
                )

            self.assertGreater(stats["completo_size_mismatch"], 0)
            self.assertTrue(any("size differs" in i for i in issues))

    def test_complete_txt_also_found(self):
        """validate_book should find *_complete.txt (current naming) as well as *_completo.txt."""
        with (
            tempfile.TemporaryDirectory() as output_dir,
            tempfile.TemporaryDirectory() as cache_dir,
        ):
            output_path = Path(output_dir)
            text_dir = output_path / "text"
            text_dir.mkdir()

            chapter_text = "B" * 500
            parsed = text_dir / "1 - Ch1-parsed.txt"
            pretts = text_dir / "1 - Ch1-pre-tts.txt"
            parsed.write_text(chapter_text)
            pretts.write_text(chapter_text)

            mp3 = output_path / "1 - Ch1.mp3"
            mp3.write_bytes(b"\xff\xfb" + b"\x00" * 4096)

            # Use current naming: *_complete.txt with CHAPTER header
            complete = output_path / "book_complete.txt"
            complete.write_text("CHAPTER 1: Ch1\n\n" + chapter_text)

            with patch(
                "validate_conversion.load_epub_chapters",
                return_value=[(1, "Ch1", chapter_text)],
            ):
                stats, issues = vc.validate_book(
                    Path("book.epub"),
                    output_dir=output_path,
                    cache_dir=Path(cache_dir),
                )

            self.assertEqual(stats["completo_size_mismatch"], 0)


class TestVerifyChapterNames(unittest.TestCase):
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


class TestVerifyMp3Integrity(unittest.TestCase):
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
