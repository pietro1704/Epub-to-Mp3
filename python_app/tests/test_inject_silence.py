"""Inject silence post-synthesis to give chapter titles a real pause.

Edge plain-text caps inter-sentence silence at ~700 ms regardless of
punctuation density. A chapter announcement like "Capítulo 1." running
straight into the body without a real beat sounds rushed; the user
reported "ainda sem pausa" / "deveria perceber sozinho".

The fix: detect the natural silence Edge produces after the title via
`silencedetect`, then splice an extra 1 s of silence at that point.
"""

from __future__ import annotations

import inspect
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src.audio_postprocess import (
    find_first_silence_after_title,
    inject_silence_at_offset,
)


class TestInjectSilenceHelpers(unittest.TestCase):
    def test_find_first_silence_after_title_signature(self):
        sig = inspect.signature(find_first_silence_after_title)
        self.assertIn("min_search_offset", sig.parameters)
        self.assertIn("max_search_offset", sig.parameters)
        self.assertEqual(sig.parameters["min_search_offset"].default, 0.4)
        self.assertEqual(sig.parameters["max_search_offset"].default, 3.5)

    def test_inject_signature_takes_seconds_and_ms(self):
        sig = inspect.signature(inject_silence_at_offset)
        self.assertIn("insert_at_seconds", sig.parameters)
        self.assertIn("silence_ms", sig.parameters)
        self.assertEqual(sig.parameters["silence_ms"].default, 1000)

    def test_converter_injection_is_opt_in_via_config(self):
        """The injection step must be gated on
        `config.inject_title_pause_ms > 0` so it stays off unless the
        user explicitly opted in via `--inject-title-pause MS`. The
        previous always-on behaviour produced fixed-length pauses that
        sounded uniform across chapters of varying length."""
        from src import converter

        src = inspect.getsource(converter)
        self.assertIn("find_silence_for_title", src)
        self.assertIn("inject_silence_at_offset", src)
        # Opt-in gate present.
        self.assertIn("inject_title_pause_ms", src)
        # The silence duration is taken from the config, not hard-coded.
        self.assertIn("silence_ms=inject_pause_ms", src)


class TestSilenceInjectionPreservesCoverArt(unittest.TestCase):
    """The post-synthesis silence injection uses ffmpeg concat-copy
    which strips non-audio streams (the embedded JPEG cover art) and
    any preceding ID3 frames. The chapter loop in `converter.py` MUST
    therefore call `_embed_id3_metadata` AFTER the injection step, not
    before — otherwise users open the audiobook on the iPhone and see
    a cover-less library.

    Source-level guard pinning the ordering.
    """

    def test_embed_id3_metadata_runs_after_inject_in_converter_loop(self):
        from src import converter

        src = inspect.getsource(converter)
        # Find positions of both call sites in the source.
        inject_pos = src.find("inject_silence_at_offset(")
        # The post-loop _embed_id3_metadata call (the one inside the
        # chapter loop, not the helper definition).
        embed_pos = src.find("self._embed_id3_metadata(", inject_pos)
        self.assertGreater(inject_pos, 0, "inject_silence_at_offset call missing")
        self.assertGreater(embed_pos, inject_pos, "ID3 embed must run AFTER inject")

    def test_main_reuse_path_reapplies_id3(self):
        """The CLI reuse short-circuit in main.py must also re-stamp
        ID3 + cover art on the existing MP3s — it skips converter.py
        entirely so the converter's final ID3 pass does not run."""
        import importlib

        spec = importlib.util.spec_from_file_location(
            "main",
            os.path.join(os.path.dirname(__file__), "..", "main.py"),
        )
        self.assertIsNotNone(spec)
        # Read the source directly to avoid heavy import side effects.
        with open(spec.origin, encoding="utf-8") as f:
            src = f.read()
        # The reuse branch (`Reusing existing output`) must apply tags.
        reuse_pos = src.find("Reusing existing output")
        self.assertGreater(reuse_pos, 0)
        apply_pos = src.find("_apply_final_id3_tags", reuse_pos)
        self.assertGreater(apply_pos, reuse_pos, "reuse path must re-stamp ID3 tags")
        # And it must pass cover_art (not None) so the JPEG is embedded.
        self.assertIn("cover_art=cover_art", src[reuse_pos : reuse_pos + 1500])


class TestInjectTitlePauseDefault(unittest.TestCase):
    """The title-pause injection used to run on every chapter with a
    hard-coded 2000 ms silence. The user found the resulting cadence
    awkward (a fixed pause is too uniform across chapters of varying
    length), so it became opt-in. Pin the new defaults."""

    def test_config_default_is_zero(self):
        from src.config import ConversionConfig

        self.assertEqual(ConversionConfig.inject_title_pause_ms, 0)

    def test_cli_default_is_zero(self):
        from main import create_argument_parser

        parser = create_argument_parser()
        ns = parser.parse_args(["convert", "x.epub"])
        self.assertEqual(getattr(ns, "inject_title_pause", None), 0)

    def test_cli_accepts_explicit_ms(self):
        from main import create_argument_parser

        parser = create_argument_parser()
        ns = parser.parse_args(["convert", "x.epub", "--inject-title-pause", "1500"])
        self.assertEqual(ns.inject_title_pause, 1500)


if __name__ == "__main__":
    unittest.main()
