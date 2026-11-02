//! Conservative generated-speech compaction before lossy encoding.
//! Only digital zero is removable: even the quietest nonzero speech is retained.

pub(crate) const PROFILE: &str = "digital-silence-v1-600ms-300ms";

pub(crate) fn compact(pcm: &[u8], rate: u32) -> Result<Vec<u8>, String> {
    if !(8_000..=96_000).contains(&rate) || pcm.is_empty() || pcm.len() % 2 != 0 {
        return Err("Expected bounded mono PCM16 for silence compaction".into());
    }
    if pcm.len() / 2 > rate as usize * 120 {
        return Err("Speech silence compaction exceeds the segment duration limit".into());
    }
    // A wholly silent response cannot establish speech; preserve it for the
    // caller's existing validation, rather than manufacturing a shorter result.
    if pcm.iter().all(|byte| *byte == 0) {
        return Ok(pcm.to_vec());
    }
    let minimum = rate as usize * 600 / 1_000;
    let retained = rate as usize * 300 / 1_000;
    let mut output = Vec::with_capacity(pcm.len());
    let mut cursor = 0;
    while cursor < pcm.len() {
        let start = cursor;
        if pcm[cursor..cursor + 2] != [0, 0] {
            output.extend_from_slice(&pcm[cursor..cursor + 2]);
            cursor += 2;
            continue;
        }
        while cursor < pcm.len() && pcm[cursor..cursor + 2] == [0, 0] {
            cursor += 2;
        }
        let frames = (cursor - start) / 2;
        // Keep 150 ms on either side of every removed interval. All edits are
        // inside a zero plateau, so boundaries introduce no amplitude jump.
        let keep = if frames >= minimum { retained } else { frames };
        output.extend_from_slice(&pcm[start..start + keep * 2]);
    }
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
            assert_eq!(compact(&pcm, rate).unwrap(), pcm);
            samples.extend(vec![0; rate as usize]);
            samples.extend([2, -2]);
            let compacted = compact(&bytes(&samples), rate).unwrap();
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
        assert_eq!(compact(&silence, 24_000).unwrap(), silence);
        for (pcm, rate) in [(vec![], 24_000), (vec![0], 24_000), (vec![0, 0], 0)] {
            assert!(compact(&pcm, rate).is_err());
        }
        assert!(compact(&vec![0; 8_000 * 121 * 2], 8_000).is_err());
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
                let output = compact(&input, rate).unwrap();
                let retained = if frames < threshold {
                    frames
                } else {
                    rate as usize * 300 / 1_000
                };
                assert_eq!(output.len(), (retained + 2) * 2);
                assert_eq!(compact(&output, rate).unwrap(), output);
            }
        }
    }
}
