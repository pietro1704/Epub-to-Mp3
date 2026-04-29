"""Filename hash stays stable across runs even when upstream input drifts.

The 2026-04-29 Carl conversion produced two MP3s for the same chapter
because tiny variations in the upstream chapter title (different
trailing word, NFKC vs NFD codepoints, leading whitespace) shifted
the SHA-1 hash and pushed the second run to a *different* truncated
filename. Cache hit failed, the chapter was re-synthesised, and both
files lingered on disk.

v0.3.16 anchors the hash on a stable 40-char NFKD-folded prefix of
the cleaned name. The tests below codify the "two-runs-same-input
converge" contract that the v0.3.11 implementation broke.
"""

from __future__ import annotations

from python_app.src.utils import FileManager


class TestSanitizeFilenameStableHash:
    def test_trailing_words_added_between_runs_keep_same_hash(self):
        # Run 1: Edge produced a slightly shorter chapter heading
        # because the auto-tuner trimmed the trailing line.
        run1 = (
            "7.1 - Parte dois - Capítulo 28 - _ muito bem disse lexis "
            "conforme eu me sentava no sofá m"
        )
        # Run 2: same chapter, different upstream post-processing kept
        # an extra phrase. Both should land on the same filename so
        # the cache lookup matches.
        run2 = (
            "7.1 - Parte dois - Capítulo 28 - _ muito bem disse lexis "
            "conforme eu me sentava no sofá minha cabeça girando. eu ai"
        )
        out1 = FileManager.sanitize_filename(run1, max_length=64)
        out2 = FileManager.sanitize_filename(run2, max_length=64)
        # Both must hit the truncate branch with the SAME hash marker.
        assert "[" in out1 and "[" in out2
        marker1 = out1[out1.rindex("[") :]
        marker2 = out2[out2.rindex("[") :]
        assert marker1 == marker2, (
            f"Marker drift between runs: {marker1!r} vs {marker2!r}. "
            "First 40 chars of both inputs are identical, hash must agree."
        )

    def test_nfkc_vs_nfd_yields_same_hash(self):
        # `é` precomposed (NFC) vs `e + combining acute` (NFD) — the
        # legacy implementation hashed raw bytes, so the two forms
        # produced different hashes despite being visually identical.
        nfc = "Capítulo 7 - exposição " + "x" * 80
        nfd = "Capi\u0301tulo 7 - exposic\u0327a\u0303o " + "x" * 80
        out_nfc = FileManager.sanitize_filename(nfc, max_length=80)
        out_nfd = FileManager.sanitize_filename(nfd, max_length=80)
        marker_nfc = out_nfc[out_nfc.rindex("[") :]
        marker_nfd = out_nfd[out_nfd.rindex("[") :]
        assert marker_nfc == marker_nfd

    def test_case_insensitive_anchor(self):
        # The visible head preserves casing for human readability,
        # but the hash anchor folds to lowercase so a re-run that
        # capitalised slightly differently still lands on the same
        # filename.
        a = "Capítulo Sete " + "y" * 80
        b = "CAPÍTULO SETE " + "y" * 80
        out_a = FileManager.sanitize_filename(a, max_length=80)
        out_b = FileManager.sanitize_filename(b, max_length=80)
        marker_a = out_a[out_a.rindex("[") :]
        marker_b = out_b[out_b.rindex("[") :]
        assert marker_a == marker_b

    def test_different_chapters_get_different_hashes(self):
        # Sanity guard: the hash MUST change when the prefix actually
        # differs — otherwise unrelated chapters would collide.
        a = "Capítulo Um — abertura " + "x" * 80
        b = "Capítulo Dois — sequência " + "x" * 80
        marker_a = FileManager.sanitize_filename(a, max_length=80)
        marker_b = FileManager.sanitize_filename(b, max_length=80)
        assert marker_a[marker_a.rindex("[") :] != marker_b[marker_b.rindex("[") :]

    def test_short_inputs_still_pass_through_verbatim(self):
        # Names under max_length skip the hash entirely so the
        # human-readable output stays intact.
        out = FileManager.sanitize_filename("Capítulo 1 - Prólogo")
        assert out == "Capítulo 1 - Prólogo"
        assert "[" not in out
