"""Cache text projection scenarios sharing the original unittest fixture."""

from python_app.tests._converter_test_support import (
    Chapter as Chapter,
    Path as Path,
)

class CacheTextProjectionCases:
    def test_cache_text_creation(self):
        """Ensure chapter text cache is written to disk."""
        cache_dir = Path(self.temp_dir)
        chapter = Chapter(1, "Cache Chapter", "ch-cache.html", "original text")
        payload = "linha 1\nlinha 2"

        self.converter._cache_text(cache_dir, chapter, 1, payload)

        expected = cache_dir / "text" / "001 - Cache Chapter.txt"
        self.assertTrue(expected.exists())
        self.assertEqual(expected.read_text(encoding="utf-8"), payload)

    def test_cached_text_matches_tts_input_simple(self):
        """Test that cached text exactly matches TTS input for simple text"""
        cache_dir = Path(self.temp_dir)

        # Simple text without formatting
        chapter = Chapter(
            index=1, name="Simple Chapter", source_path="ch1.html", text="This is a simple test."
        )

        # Get what would be sent to TTS
        tts_input = self.converter._speech_text(chapter)

        # Cache it
        self.converter._cache_text(cache_dir, chapter, 1, tts_input)

        # Read back
        cached_path = cache_dir / "text" / "001 - Simple Chapter.txt"
        cached_text = cached_path.read_text(encoding="utf-8")

        # MUST BE IDENTICAL
        self.assertEqual(cached_text, tts_input, "Cached text must exactly match TTS input")
        self.assertEqual(
            cached_text, "This is a simple test.", "Cached text should preserve simple text exactly"
        )

    def test_cached_text_matches_tts_input_with_language_tags(self):
        """Test that cached text preserves language tags exactly as sent to TTS"""
        cache_dir = Path(self.temp_dir)

        # Text with language tags
        text_with_tags = "English text [[lang:pt-BR]]Texto em português[[/lang]] back to English"

        chapter = Chapter(
            index=2, name="Multilingual Chapter", source_path="ch2.html", text=text_with_tags
        )

        # Get what would be sent to TTS
        tts_input = self.converter._speech_text(chapter)

        # Cache it
        self.converter._cache_text(cache_dir, chapter, 2, tts_input)

        # Read back
        cached_path = cache_dir / "text" / "002 - Multilingual Chapter.txt"
        cached_text = cached_path.read_text(encoding="utf-8")

        # MUST BE IDENTICAL
        self.assertEqual(
            cached_text, tts_input, "Cached text must exactly match TTS input with language tags"
        )

        # Should contain the language tags
        self.assertIn(
            "[[lang:pt-BR]]", cached_text, "Language tags should be preserved in cached text"
        )
        self.assertIn(
            "[[/lang]]", cached_text, "Closing language tags should be preserved in cached text"
        )

    def test_cached_text_matches_tts_input_with_speech_text(self):
        """Test that cached text uses speech_text when available"""
        cache_dir = Path(self.temp_dir)

        # Chapter with separate speech_text
        chapter = Chapter(
            index=3,
            name="Speech Chapter",
            source_path="ch3.html",
            text="Original text with HTML",
            speech_text="Processed speech text with [[lang:pt-BR]]português[[/lang]]",
        )

        # Get what would be sent to TTS
        tts_input = self.converter._speech_text(chapter)

        # Should use speech_text, not text
        self.assertEqual(
            tts_input, chapter.speech_text, "_speech_text should return speech_text when available"
        )

        # Cache it
        self.converter._cache_text(cache_dir, chapter, 3, tts_input)

        # Read back
        cached_path = cache_dir / "text" / "003 - Speech Chapter.txt"
        cached_text = cached_path.read_text(encoding="utf-8")

        # MUST BE IDENTICAL to speech_text
        self.assertEqual(cached_text, tts_input, "Cached text must match TTS input (speech_text)")
        self.assertEqual(
            cached_text, chapter.speech_text, "Cached text should use speech_text when available"
        )

    def test_parse_txt_vs_tts_input_txt_files(self):
        """Test that parse.txt and tts_input.txt are saved correctly"""
        cache_dir = Path(self.temp_dir)

        # Chapter where text != speech_text
        chapter = Chapter(
            index=5,
            name="Dual Text Chapter",
            source_path="ch5.html",
            text="Original parsed text from EPUB",
            speech_text="Processed speech text [[lang:pt-BR]]with tags[[/lang]]",
        )

        # Get what would be sent to TTS
        tts_input = self.converter._speech_text(chapter)

        # Should use speech_text
        self.assertEqual(tts_input, chapter.speech_text)

        # Simulate caching (as done in converter.py)
        target_dir = cache_dir / "text"
        target_dir.mkdir(parents=True, exist_ok=True)
        safe_name = "Dual_Text_Chapter"

        # Save both files (NEW FORMAT: "N - Name-parsed.txt")
        parse_path = target_dir / f"5 - {safe_name}-parsed.txt"
        parse_path.write_text(chapter.text or "", encoding="utf-8")

        pre_tts_path = target_dir / f"5 - {safe_name}-pre-tts.txt"
        pre_tts_path.write_text(tts_input, encoding="utf-8")

        # Verify both files exist
        self.assertTrue(parse_path.exists(), "parsed.txt should exist")
        self.assertTrue(pre_tts_path.exists(), "pre-tts.txt should exist")

        # Read back
        parse_content = parse_path.read_text(encoding="utf-8")
        pre_tts_content = pre_tts_path.read_text(encoding="utf-8")

        # Verify parsed.txt has original text
        self.assertEqual(
            parse_content, chapter.text, "parsed.txt should contain original chapter.text"
        )

        # Verify pre-tts.txt has speech_text
        self.assertEqual(
            pre_tts_content, chapter.speech_text, "pre-tts.txt should contain speech_text"
        )
        self.assertEqual(pre_tts_content, tts_input, "pre-tts.txt should match what goes to TTS")

        # They should be DIFFERENT in this case
        self.assertNotEqual(
            parse_content,
            pre_tts_content,
            "parsed.txt and pre-tts.txt should differ when text != speech_text",
        )

        # Verify language tags are in pre-tts but not in parse
        self.assertIn("[[lang:pt-BR]]", pre_tts_content)
        self.assertNotIn("[[lang:pt-BR]]", parse_content)

    def test_cached_text_matches_tts_input_with_pauses(self):
        """Test that cached text preserves pause markers (ellipsis)"""
        cache_dir = Path(self.temp_dir)

        # Text with pauses
        text_with_pauses = "Wait... for it... now!"

        chapter = Chapter(
            index=4, name="Pause Chapter", source_path="ch4.html", text=text_with_pauses
        )

        # Get what would be sent to TTS
        tts_input = self.converter._speech_text(chapter)

        # Cache it
        self.converter._cache_text(cache_dir, chapter, 4, tts_input)

        # Read back
        cached_path = cache_dir / "text" / "004 - Pause Chapter.txt"
        cached_text = cached_path.read_text(encoding="utf-8")

        # MUST BE IDENTICAL
        self.assertEqual(
            cached_text, tts_input, "Cached text must exactly match TTS input with pauses"
        )

        # Should preserve ellipsis
        self.assertEqual(
            cached_text.count("..."), 2, "Pause markers (ellipsis) should be preserved"
        )
