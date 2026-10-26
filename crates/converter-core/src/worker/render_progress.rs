//! Text-weighted progress. Cached audio advances work, never synthesis throughput.
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, VecDeque};

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RenderProgressSnapshot {
    pub fraction: f64,
    pub eta_seconds: Option<f64>,
    pub fresh_chars_per_second: Option<f64>,
    pub cached_segments: usize,
}

#[derive(Default)]
pub(super) struct RenderProgress {
    weights: BTreeMap<usize, usize>,
    done: BTreeMap<usize, usize>,
    samples: VecDeque<(usize, f64)>,
    cached_segments: usize,
}

impl RenderProgress {
    pub fn new(weights: impl IntoIterator<Item = (usize, usize)>) -> Self {
        Self {
            weights: weights.into_iter().collect(),
            ..Self::default()
        }
    }

    pub fn segment(&mut self, chapter: usize, chars: usize, wall: f64, cached: bool) {
        let Some(weight) = self.weights.get(&chapter) else {
            return;
        };
        let done = self.done.entry(chapter).or_default();
        let accepted = chars.min(weight.saturating_sub(*done));
        *done += accepted;
        if cached {
            self.cached_segments += 1;
        } else if accepted > 0 && wall.is_finite() && wall > 0.0 {
            self.samples.push_back((accepted, wall));
            if self.samples.len() > 12 {
                self.samples.pop_front();
            }
        }
    }

    pub fn complete(&mut self, chapter: usize) {
        if let Some(weight) = self.weights.get(&chapter) {
            self.done.insert(chapter, *weight);
        }
    }

    pub fn snapshot(&self) -> Option<RenderProgressSnapshot> {
        let total: usize = self.weights.values().sum();
        if total == 0 {
            return None;
        }
        let done = self.done.values().sum::<usize>().min(total);
        let chars: usize = self.samples.iter().map(|(chars, _)| chars).sum();
        let wall: f64 = self.samples.iter().map(|(_, wall)| wall).sum();
        let rate = (chars > 0 && wall.is_finite() && wall > 0.0).then(|| chars as f64 / wall);
        Some(RenderProgressSnapshot {
            fraction: done as f64 / total as f64,
            eta_seconds: rate.map(|rate| (total - done) as f64 / rate),
            fresh_chars_per_second: rate,
            cached_segments: self.cached_segments,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cached_work_does_not_fabricate_a_rate_and_chapters_are_weighted() {
        let mut progress = RenderProgress::new([(0, 100), (1, 900)]);
        progress.complete(0);
        let first = progress.snapshot().unwrap();
        assert_eq!(first.fraction, 0.1);
        assert_eq!(first.eta_seconds, None);
        progress.segment(1, 100, 2.0, false);
        progress.segment(1, 100, 0.001, true);
        let next = progress.snapshot().unwrap();
        assert_eq!(next.fresh_chars_per_second, Some(50.0));
        assert_eq!(next.eta_seconds, Some(14.0));
        assert_eq!(next.cached_segments, 1);
    }
    #[test]
    fn invalid_samples_unknown_chapters_and_late_completion_are_bounded() {
        let mut progress = RenderProgress::new([(7, 50)]);
        progress.segment(8, 10, 1.0, false);
        progress.segment(7, 10, f64::NAN, false);
        assert_eq!(progress.snapshot().unwrap().eta_seconds, None);
        progress.complete(7);
        progress.segment(7, 100, 1.0, false);
        assert_eq!(progress.snapshot().unwrap().fraction, 1.0);
        assert_eq!(progress.snapshot().unwrap().fresh_chars_per_second, None);
        let fresh = RenderProgress::new([(7, 50)]);
        assert_eq!(fresh.snapshot().unwrap().fraction, 0.0);
    }
}
