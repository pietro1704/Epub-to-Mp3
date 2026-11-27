//! Conservative generated-speech compaction before lossy encoding.
//! Only digital zero is removable: even the quietest nonzero speech is retained.

use crate::tts_preferences::SilenceTrim;

/// Cache/artifact identity of the light level. It keeps the pre-levels name, so audio generated
/// before levels existed stays valid for the default.
pub(crate) const PROFILE: &str = "digital-silence-v1-600ms-300ms";

/// Samples at or below this magnitude count as silence at the strong level (about -60 dBFS).
const STRONG_NEAR_SILENCE: u16 = 32;

/// Parameters of one level: a run of silence at least `min_ms` long is cut down to `keep_ms`;
/// samples with magnitude up to `floor` are silence.
struct Rule {
    min_ms: usize,
    keep_ms: usize,
    floor: u16,
}

fn rule(level: SilenceTrim) -> Option<Rule> {
    match level {
        SilenceTrim::Off => None,
        SilenceTrim::Light => Some(Rule { min_ms: 600, keep_ms: 300, floor: 0 }),
        SilenceTrim::Medium => Some(Rule { min_ms: 400, keep_ms: 200, floor: 0 }),
        SilenceTrim::Strong => Some(Rule { min_ms: 250, keep_ms: 120, floor: STRONG_NEAR_SILENCE }),
    }
}

/// Identity of the processing applied at `level`, part of every audio cache key.
pub(crate) fn profile(level: SilenceTrim) -> &'static str {
    match level {
        SilenceTrim::Off => "silence-off-v1",
        SilenceTrim::Light => PROFILE,
        SilenceTrim::Medium => "digital-silence-v1-400ms-200ms",
        SilenceTrim::Strong => "near-silence-v1-250ms-120ms-floor32",
    }
}

/// Removed intervals in original sample coordinates, shared with word timing.
pub(crate) fn removed_ranges(pcm: &[u8], rate: u32, level: SilenceTrim) -> Vec<(usize, usize)> {
    let Some(rule) = rule(level) else {
        return Vec::new();
    };
    let quiet = |at: usize| {
        i16::from_le_bytes([pcm[at], pcm[at + 1]]).unsigned_abs() <= rule.floor
    };
    if (0..pcm.len() / 2).all(|i| quiet(i * 2)) {
        return Vec::new();
    }
    let min = rate as usize * rule.min_ms / 1_000;
    let keep = rate as usize * rule.keep_ms / 1_000;
    let mut ranges = Vec::new();
    let mut cursor = 0;
    while cursor + 1 < pcm.len() {
        if !quiet(cursor) {
            cursor += 2;
            continue;
        }
        let start = cursor / 2;
        while cursor + 1 < pcm.len() && quiet(cursor) {
            cursor += 2;
        }
        let end = cursor / 2;
        if end - start >= min {
            ranges.push((start + keep, end));
        }
    }
    ranges
}

pub(crate) fn compact(pcm: &[u8], rate: u32, level: SilenceTrim) -> Result<Vec<u8>, String> {
    if !(8_000..=96_000).contains(&rate) || pcm.is_empty() || pcm.len() % 2 != 0 {
        return Err("Expected bounded mono PCM16 for silence compaction".into());
    }
    if pcm.len() / 2 > rate as usize * 120 {
        return Err("Speech silence compaction exceeds the segment duration limit".into());
    }
    // A wholly silent response cannot establish speech; preserve it for the
    // caller's existing validation, rather than manufacturing a shorter result.
    let mut output = Vec::with_capacity(pcm.len());
    let mut cursor = 0;
    for (start, end) in removed_ranges(pcm, rate, level) {
        output.extend_from_slice(&pcm[cursor..start * 2]);
        cursor = end * 2;
    }
    output.extend_from_slice(&pcm[cursor..]);
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bytes(samples: &[i16]) -> Vec<u8> {
        samples.iter().flat_map(|s| s.to_le_bytes()).collect()
    }

    #[test]
    fn retains_every_nonzero_sample_and_short_pause_at_each_rate() {
        for rate in [8_000, 16_000, 22_050, 24_000, 48_000, 96_000] {
            let mut samples = vec![1, -1, i16::MIN, i16::MAX];
            samples.extend(vec![0; rate as usize / 5]);
            samples.extend([1, -1]);
            let pcm = bytes(&samples);
            assert_eq!(compact(&pcm, rate, SilenceTrim::Light).unwrap(), pcm);
            samples.extend(vec![0; rate as usize]);
            samples.extend([2, -2]);
            let compacted = compact(&bytes(&samples), rate, SilenceTrim::Light).unwrap();
            let kept: Vec<_> = compacted
                .chunks_exact(2)
                .map(|b| i16::from_le_bytes([b[0], b[1]]))
                .filter(|s| *s != 0)
                .collect();
            assert_eq!(kept, [1, -1, i16::MIN, i16::MAX, 1, -1, 2, -2]);
            assert_eq!(
                compacted.len() / 2,
                8 + rate as usize / 5 + rate as usize * 300 / 1_000
            );
        }
    }

    #[test]
    fn preserves_silent_responses_and_rejects_invalid_input() {
        let silence = vec![0; 48_000];
        assert_eq!(compact(&silence, 24_000, SilenceTrim::Light).unwrap(), silence);
        for (pcm, rate) in [(vec![], 24_000), (vec![0], 24_000), (vec![0, 0], 0)] {
            assert!(compact(&pcm, rate, SilenceTrim::Light).is_err());
        }
        assert!(compact(&vec![0; 8_000 * 121 * 2], 8_000, SilenceTrim::Light).is_err());
    }

    #[test]
    fn threshold_is_inclusive_and_compaction_is_idempotent() {
        for rate in [8_000, 22_050, 96_000] {
            let threshold = rate as usize * 600 / 1_000;
            for frames in [threshold - 1, threshold, threshold + 1] {
                let mut samples = vec![1];
                samples.extend(vec![0; frames]);
                samples.push(-1);
                let input = bytes(&samples);
                let output = compact(&input, rate, SilenceTrim::Light).unwrap();
                let retained = if frames < threshold {
                    frames
                } else {
                    rate as usize * 300 / 1_000
                };
                assert_eq!(output.len(), (retained + 2) * 2);
                assert_eq!(compact(&output, rate, SilenceTrim::Light).unwrap(), output);
            }
        }
    }
}
