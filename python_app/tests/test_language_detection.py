import unittest
from unittest.mock import Mock

from main import ChapterStructureItem, ConverterApplication
from src.ebook_reader import Chapter
from src.language.detector import LanguagePrediction, LanguageProfile


class TestLanguageDetection(unittest.TestCase):
    def setUp(self) -> None:
        self.app = ConverterApplication()

    def _build_items(self, count: int) -> list[ChapterStructureItem]:
        items: list[ChapterStructureItem] = []
        for idx in range(count):
            chapter = Chapter(
                index=idx,
                name=f"Chapter {idx}",
                source_path=f"chapter_{idx}.xhtml",
                text=f"default text {idx}",
            )
            item = ChapterStructureItem(
                chapter=chapter,
                index=f"{idx}.0",
                main_title=f"Section {idx}",
                sub_title=None,
                preview=None,
                display_name=f"{idx}.0 - Section {idx}",
                text_override=f"sample_text_{idx}",
            )
            items.append(item)
        return items

    def test_prepare_language_profile_spreads_sampling(self) -> None:
        items = self._build_items(30)
        mock_reader = Mock()
        mock_reader.title = "Test Book"

        fake_profile = LanguageProfile(
            primary="en", languages=["en"], predictions=[], analysed_chars=0
        )
        detect_mock = Mock(return_value=fake_profile)
        self.app.language_detector.detect_profile = detect_mock  # type: ignore

        self.app._prepare_language_profile(mock_reader, items)

        detect_mock.assert_called_once()
        sample_texts = detect_mock.call_args.args[0]
        self.assertIn("sample_text_0", sample_texts)
        self.assertIn("sample_text_29", sample_texts)
        self.assertGreaterEqual(len(sample_texts), min(20, len(items)))

    def test_rebalance_language_profile_prefers_english_when_ascii_high(self) -> None:
        profile = LanguageProfile(
            primary="pt",
            languages=["pt"],
            predictions=[
                LanguagePrediction(code="pt", probability=0.64),
                LanguagePrediction(code="en", probability=0.55),
            ],
            analysed_chars=3200,
        )
        adjusted = self.app._rebalance_language_profile(
            profile, ascii_ratio=0.85, language_votes={}
        )
        self.assertEqual(adjusted.primary, "en")
        self.assertEqual(adjusted.languages[0], "en")

    def test_language_votes_override_profile(self) -> None:
        profile = LanguageProfile(
            primary="pt",
            languages=["pt"],
            predictions=[
                LanguagePrediction(code="pt", probability=0.8),
                LanguagePrediction(code="en", probability=0.3),
            ],
            analysed_chars=5000,
        )
        votes = {"en": 1500.0, "pt": 400.0}
        adjusted = self.app._rebalance_language_profile(
            profile, ascii_ratio=0.2, language_votes=votes
        )
        self.assertEqual(adjusted.primary, "en")
        self.assertEqual(adjusted.languages[0], "en")


if __name__ == "__main__":
    unittest.main()
