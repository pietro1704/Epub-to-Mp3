# -*- coding: utf-8 -*-
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
            mp3_path.write_bytes(b"fake mp3 data" * 200)

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
                any("duplicad" in issue.lower() for issue in issues),
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
