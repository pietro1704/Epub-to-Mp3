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
