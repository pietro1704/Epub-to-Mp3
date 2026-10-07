//! Provider-neutral feedback policy for remote synthesis request throughput.

use std::{
    sync::{Mutex, MutexGuard},
    time::{Duration, Instant},
};

use tokio::sync::Notify;

pub const INITIAL_CHUNK_CHARS: usize = 4_096;
pub const MIN_CHUNK_CHARS: usize = 2_048;
pub const MAX_CHUNK_CHARS: usize = 6_144;
pub const INITIAL_MAX_IN_FLIGHT: usize = 2;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProviderFailure {
    Throttled { retry_after: Option<Duration> },
    Timeout,
    Transient,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AdaptiveSnapshot {
    pub chunk_chars: usize,
    pub max_in_flight: usize,
    pub in_flight: usize,
    pub stable_successes: usize,
    pub slow_requests: usize,
    pub throttles: usize,
    pub cooldown_remaining: Duration,
}

#[derive(Clone, Copy, Debug)]
pub struct AdaptiveConfig {
    pub initial_chunk_chars: usize,
    pub min_chunk_chars: usize,
    pub max_chunk_chars: usize,
    pub initial_max_in_flight: usize,
    pub min_max_in_flight: usize,
    pub max_max_in_flight: usize,
    pub success_window: usize,
    pub fast_chars_per_second: f64,
    pub slow_chars_per_second: f64,
    pub throttle_cooldown: Duration,
    pub max_cooldown: Duration,
    pub timeout_cooldown: Duration,
}

impl Default for AdaptiveConfig {
    fn default() -> Self {
        Self {
            initial_chunk_chars: INITIAL_CHUNK_CHARS,
            min_chunk_chars: MIN_CHUNK_CHARS,
            max_chunk_chars: MAX_CHUNK_CHARS,
            initial_max_in_flight: INITIAL_MAX_IN_FLIGHT,
            min_max_in_flight: 1,
            max_max_in_flight: INITIAL_MAX_IN_FLIGHT,
            success_window: 4,
            fast_chars_per_second: 500.0,
            slow_chars_per_second: 250.0,
            throttle_cooldown: Duration::from_secs(12),
            max_cooldown: Duration::from_secs(120),
            timeout_cooldown: Duration::from_secs(3),
        }
    }
}

#[derive(Debug)]
struct AdaptiveState {
    chunk_chars: usize,
    max_in_flight: usize,
    in_flight: usize,
    stable_successes: usize,
    consecutive_slow: usize,
    throttles: usize,
    cooldown_until: Option<Instant>,
}

/// Shared by every remote request in a single conversion run.
pub struct AdaptiveThroughputController {
    config: AdaptiveConfig,
    state: Mutex<AdaptiveState>,
    capacity_changed: Notify,
}

impl Default for AdaptiveThroughputController {
    fn default() -> Self {
        Self::new(AdaptiveConfig::default())
    }
}

impl AdaptiveThroughputController {
    pub fn new(config: AdaptiveConfig) -> Self {
        let min_chunk_chars = config.min_chunk_chars.max(1);
        let max_chunk_chars = config.max_chunk_chars.max(min_chunk_chars);
        let initial_chunk_chars = config
            .initial_chunk_chars
            .clamp(min_chunk_chars, max_chunk_chars);
        let min_max_in_flight = config.min_max_in_flight.max(1);
        let max_max_in_flight = config.max_max_in_flight.max(min_max_in_flight);
        let initial_max_in_flight = config
            .initial_max_in_flight
            .clamp(min_max_in_flight, max_max_in_flight);
        Self {
            config: AdaptiveConfig {
                min_chunk_chars,
                max_chunk_chars,
                initial_chunk_chars,
                min_max_in_flight,
                max_max_in_flight,
                initial_max_in_flight,
                ..config
            },
            state: Mutex::new(AdaptiveState {
                chunk_chars: initial_chunk_chars,
                max_in_flight: initial_max_in_flight,
                in_flight: 0,
                stable_successes: 0,
                consecutive_slow: 0,
                throttles: 0,
                cooldown_until: None,
            }),
            capacity_changed: Notify::new(),
        }
    }

    pub fn snapshot(&self) -> AdaptiveSnapshot {
        let state = self.lock_state();
        let now = Instant::now();
        AdaptiveSnapshot {
            chunk_chars: state.chunk_chars,
            max_in_flight: state.max_in_flight,
            in_flight: state.in_flight,
            stable_successes: state.stable_successes,
            slow_requests: state.consecutive_slow,
            throttles: state.throttles,
            cooldown_remaining: state
                .cooldown_until
                .map(|until| until.saturating_duration_since(now))
                .unwrap_or_default(),
        }
    }

    pub fn observe_success(&self, chars: usize, elapsed: Duration, retries: usize) {
        // Tiny chapters and tail fragments are latency-dominated and do not
        // indicate the provider's sustainable request throughput. Let them
        // complete without steering the shared controller; a retried fragment
        // still carries a real pressure signal.
        if chars < self.config.min_chunk_chars && retries == 0 {
            return;
        }
        let chars_per_second = chars as f64 / elapsed.as_secs_f64().max(0.001);
        let mut state = self.lock_state();
        state.throttles = 0;

        if retries > 0 || chars_per_second < self.config.slow_chars_per_second {
            state.stable_successes = 0;
            state.consecutive_slow += 1;
            if retries > 0 || state.consecutive_slow >= 2 {
                state.chunk_chars = (state.chunk_chars * 3 / 4).max(self.config.min_chunk_chars);
                state.max_in_flight = state
                    .max_in_flight
                    .saturating_sub(1)
                    .max(self.config.min_max_in_flight);
                state.consecutive_slow = 0;
            }
            drop(state);
            self.capacity_changed.notify_waiters();
            return;
        }

        state.consecutive_slow = 0;
        if chars_per_second >= self.config.fast_chars_per_second {
            state.stable_successes += 1;
            if state.stable_successes >= self.config.success_window.max(1) {
                state.chunk_chars = state
                    .chunk_chars
                    .saturating_add(1_024)
                    .min(self.config.max_chunk_chars);
                state.max_in_flight = (state.max_in_flight + 1).min(self.config.max_max_in_flight);
                state.stable_successes = 0;
            }
        } else {
            state.stable_successes = 0;
        }
        drop(state);
        self.capacity_changed.notify_waiters();
    }

    pub fn observe_failure(&self, failure: ProviderFailure) {
        let mut state = self.lock_state();
        state.stable_successes = 0;
        state.consecutive_slow = 0;
        let now = Instant::now();
        let cooldown = match failure {
            ProviderFailure::Throttled { retry_after } => {
                state.throttles = state.throttles.saturating_add(1);
                state.chunk_chars = (state.chunk_chars / 2).max(self.config.min_chunk_chars);
                state.max_in_flight = state
                    .max_in_flight
                    .saturating_sub(1)
                    .max(self.config.min_max_in_flight);
                let multiplier = 1u32 << state.throttles.saturating_sub(1).min(10);
                self.config
                    .throttle_cooldown
                    .saturating_mul(multiplier)
                    .min(self.config.max_cooldown)
                    .max(retry_after.unwrap_or_default())
            }
            ProviderFailure::Timeout => {
                state.chunk_chars = (state.chunk_chars * 3 / 4).max(self.config.min_chunk_chars);
                state.max_in_flight = state
                    .max_in_flight
                    .saturating_sub(1)
                    .max(self.config.min_max_in_flight);
                self.config.timeout_cooldown
            }
            ProviderFailure::Transient => {
                state.max_in_flight = state
                    .max_in_flight
                    .saturating_sub(1)
                    .max(self.config.min_max_in_flight);
                self.config.timeout_cooldown
            }
        };
        let cooldown_until = now + cooldown;
        state.cooldown_until = Some(
            state
                .cooldown_until
                .map(|current| current.max(cooldown_until))
                .unwrap_or(cooldown_until),
        );
        drop(state);
        self.capacity_changed.notify_waiters();
    }

    pub async fn acquire_request(self: &std::sync::Arc<Self>) -> AdaptiveRequestPermit {
        loop {
            let notified = self.capacity_changed.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();

            let cooldown = {
                let mut state = self.lock_state();
                let now = Instant::now();
                let cooldown = state
                    .cooldown_until
                    .map(|until| until.saturating_duration_since(now))
                    .unwrap_or_default();
                if cooldown.is_zero() && state.in_flight < state.max_in_flight {
                    state.in_flight += 1;
                    return AdaptiveRequestPermit {
                        controller: std::sync::Arc::clone(self),
                    };
                }
                cooldown
            };

            if cooldown.is_zero() {
                notified.await;
            } else {
                tokio::select! {
                    _ = tokio::time::sleep(cooldown) => {},
                    _ = notified => {},
                }
            }
        }
    }

    fn lock_state(&self) -> MutexGuard<'_, AdaptiveState> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

pub struct AdaptiveRequestPermit {
    controller: std::sync::Arc<AdaptiveThroughputController>,
}

impl Drop for AdaptiveRequestPermit {
    fn drop(&mut self) {
        let mut state = self.controller.lock_state();
        state.in_flight = state.in_flight.saturating_sub(1);
        drop(state);
        self.controller.capacity_changed.notify_waiters();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fast_success(controller: &AdaptiveThroughputController) {
        controller.observe_success(4_096, Duration::from_secs(4), 0);
    }

    #[test]
    fn starts_at_measured_safe_profile_and_grows_after_stable_fast_chunks() {
        let controller = AdaptiveThroughputController::default();
        let initial = controller.snapshot();
        assert_eq!(initial.chunk_chars, 4_096);
        assert_eq!(initial.max_in_flight, 2);

        for _ in 0..3 {
            fast_success(&controller);
        }
        assert_eq!(controller.snapshot().chunk_chars, 4_096);
        fast_success(&controller);

        let adapted = controller.snapshot();
        assert_eq!(adapted.chunk_chars, 5_120);
        assert_eq!(adapted.max_in_flight, 2);
    }

    #[test]
    fn slow_chunks_reduce_request_size_and_repeated_slow_chunks_reduce_concurrency() {
        let controller = AdaptiveThroughputController::default();
        controller.observe_success(4_096, Duration::from_secs(20), 0);
        assert_eq!(controller.snapshot().chunk_chars, 4_096);
        controller.observe_success(4_096, Duration::from_secs(20), 0);

        let adapted = controller.snapshot();
        assert_eq!(adapted.chunk_chars, 3_072);
        assert_eq!(adapted.max_in_flight, 1);
    }

    #[test]
    fn short_chapters_do_not_reduce_remote_request_capacity() {
        let controller = AdaptiveThroughputController::default();
        controller.observe_success(74, Duration::from_millis(1_327), 0);
        controller.observe_success(2, Duration::from_millis(1_116), 0);

        let adapted = controller.snapshot();
        assert_eq!(adapted.chunk_chars, 4_096);
        assert_eq!(adapted.max_in_flight, 2);
    }

    #[test]
    fn throttling_halves_chunks_reduces_concurrency_and_honors_retry_after() {
        let controller = AdaptiveThroughputController::default();
        controller.observe_failure(ProviderFailure::Throttled {
            retry_after: Some(Duration::from_secs(30)),
        });

        let adapted = controller.snapshot();
        assert_eq!(adapted.chunk_chars, 2_048);
        assert_eq!(adapted.max_in_flight, 1);
        assert_eq!(adapted.throttles, 1);
        assert!(adapted.cooldown_remaining >= Duration::from_secs(29));
    }

    #[tokio::test]
    async fn request_gate_respects_a_lowered_provider_concurrency() {
        let controller = std::sync::Arc::new(AdaptiveThroughputController::new(AdaptiveConfig {
            throttle_cooldown: Duration::from_millis(10),
            max_cooldown: Duration::from_millis(100),
            ..AdaptiveConfig::default()
        }));
        let first = controller.acquire_request().await;
        let second = controller.acquire_request().await;
        controller.observe_failure(ProviderFailure::Throttled { retry_after: None });

        let waiting_controller = std::sync::Arc::clone(&controller);
        let mut waiting = tokio::spawn(async move { waiting_controller.acquire_request().await });
        drop(first);
        assert!(tokio::time::timeout(Duration::from_millis(2), &mut waiting)
            .await
            .is_err());
        drop(second);
        let permit = tokio::time::timeout(Duration::from_secs(1), &mut waiting)
            .await
            .expect("the lowered request gate must reopen after cooldown")
            .expect("the waiter must not be cancelled");
        assert_eq!(controller.snapshot().in_flight, 1);
        drop(permit);
    }
}
