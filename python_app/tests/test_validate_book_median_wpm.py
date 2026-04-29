"""Median-based duration outlier detection in validate_book.

Replaces the static `chars/WPM=150 ± 60-70%` rule with a per-book
median: collect each chapter's actual WPM in a first pass, then flag
only chapters whose WPM falls outside [50%, 200%] of the median.

This fixes the v0.3.13 false positives where Edge-TTS PT-BR neural
voices speaking 91-97 WPM (perfectly normal for that engine on this
book) tripped the +60% threshold against the 150-WPM baseline. With
the median pulled from the book itself, those chapters look like
"the typical speed" instead of outliers, and only chapters that drift
substantially from the *book's own* distribution get flagged.
"""

from __future__ import annotations

from validate_conversion import _wpm_outlier_bounds


class TestWpmOutlierBounds:
    def test_returns_none_when_too_few_samples(self):
        # Need ≥ 5 chapters to anchor a distribution.
        for n in range(5):
            assert _wpm_outlier_bounds([100.0] * n) is None

    def test_median_anchored_at_typical_speed(self):
        wpms = [95, 100, 105, 110, 92, 98, 102, 99, 101]
        result = _wpm_outlier_bounds([float(w) for w in wpms])
        assert result is not None
        median, low, high = result
        assert 95 <= median <= 105
        assert low == median * 0.50
        assert high == median * 2.00

    def test_extreme_outliers_excluded_from_median(self):
        # One pathological 600 WPM measurement (impossible) is sanity-stripped
        # before the median is computed, so it doesn't shift the bounds.
        wpms = [95.0, 100.0, 105.0, 110.0, 92.0, 600.0, 5.0]
        result = _wpm_outlier_bounds(wpms)
        assert result is not None
        median, _, _ = result
        # Median of the 5 sane values (92, 95, 100, 105, 110) is 100.
        assert median == 100.0

    def test_median_for_pt_br_edge_neural_voices(self):
        # Real measured WPMs from the Carl conversion. The legacy 150
        # baseline flagged half of these; with the median (≈ 99) the
        # acceptable band [49.5, 198] catches only true outliers.
        wpms = [55.0, 91.0, 93.0, 97.0, 99.0, 102.0, 145.0, 165.0, 180.0]
        result = _wpm_outlier_bounds(wpms)
        assert result is not None
        median, low, high = result
        assert 95 <= median <= 105  # carl's typical speaking rate
        # 145 WPM (the upper bound of "fast Edge PT-BR") is well inside.
        assert 145 < high
        # 180 WPM is at the high end of normal Edge speed — must NOT be
        # flagged as an outlier. The legacy WPM=150 + 60% tolerance
        # rejected it; the median-based bound (≈ 198) accepts it.
        assert 180 <= high

    def test_genuinely_slow_audio_is_flagged(self):
        # Body of the book sits around 100 WPM; a chapter that comes
        # back at 30 WPM is audibly broken (likely silence padding bug
        # or duplicated segments) and must get flagged.
        wpms = [95, 100, 105, 110, 92, 98, 102, 99, 101]
        result = _wpm_outlier_bounds([float(w) for w in wpms])
        assert result is not None
        _, low, _ = result
        assert 30.0 < low  # 30 WPM is below the 50%-of-median bound

    def test_returns_none_when_all_samples_invalid(self):
        # All samples outside the [30, 400] sanity range → not enough data.
        assert _wpm_outlier_bounds([5.0, 10.0, 500.0, 600.0]) is None
