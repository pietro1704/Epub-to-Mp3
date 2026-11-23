//! Background CPU pacing for on-device synthesis.
//!
//! iOS kills a process that keeps the CPU busy in the background (`cpu usage` resource limit: more than 80% of
//! one core over 60 s). Local Piper synthesis is pure CPU, so a locked phone that synthesizes as fast as it can
//! is terminated within a minute (observed on the iPhone 16e: 48 s CPU in 50 s, process killed). While the app
//! says it is in the background, every synthesized segment is followed by a rest that keeps the process's CPU
//! duty cycle at or below the configured percentage; in the foreground nothing changes.

use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

/// Percent of one core the process may use while backgrounded; 0 means unpaced (foreground).
static BACKGROUND_CPU_LIMIT_PERCENT: AtomicU32 = AtomicU32::new(0);

/// A single rest never exceeds this, so a stale limit cannot freeze a job.
const MAXIMUM_REST: Duration = Duration::from_secs(60);
const REST_SLICE: Duration = Duration::from_millis(50);

/// Sets the background CPU budget (1..=100 percent of one core) or lifts it with 0. Applies to every running job.
pub fn set_background_cpu_limit_percent(percent: u32) {
    BACKGROUND_CPU_LIMIT_PERCENT.store(percent.min(100), Ordering::Relaxed);
}

pub fn background_cpu_limit_percent() -> u32 {
    BACKGROUND_CPU_LIMIT_PERCENT.load(Ordering::Relaxed)
}

/// CPU time this whole process has used so far, when the platform reports it.
#[cfg(unix)]
pub fn process_cpu_time() -> Option<Duration> {
    let mut spec = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: `spec` is a valid, writable timespec for the duration of the call.
    let status = unsafe { libc::clock_gettime(libc::CLOCK_PROCESS_CPUTIME_ID, &mut spec) };
    (status == 0).then(|| Duration::new(spec.tv_sec.max(0) as u64, spec.tv_nsec.max(0) as u32))
}

#[cfg(not(unix))]
pub fn process_cpu_time() -> Option<Duration> {
    None
}

/// The rest that keeps `cpu_used / (wall_elapsed + rest)` at or below `limit_percent`.
pub fn rest_for(cpu_used: Duration, wall_elapsed: Duration, limit_percent: u32) -> Duration {
    if limit_percent == 0 {
        return Duration::ZERO;
    }
    let needed_wall = cpu_used.mul_f64(100.0 / f64::from(limit_percent.min(100)));
    needed_wall.saturating_sub(wall_elapsed).min(MAXIMUM_REST)
}

/// Measures one unit of synthesis so the caller can rest afterwards.
pub(crate) struct DutyCycle {
    wall: Instant,
    cpu: Option<Duration>,
}

impl DutyCycle {
    pub(crate) fn begin() -> Self {
        Self {
            wall: Instant::now(),
            cpu: process_cpu_time(),
        }
    }

    /// Rests (in short slices) after the work when the background limit is set. Returns early on cancellation
    /// or as soon as the limit is lifted (the app came back to the foreground).
    pub(crate) fn rest_if_backgrounded(&self, cancelled: &dyn Fn() -> bool) {
        self.rest_with_limit(&|| background_cpu_limit_percent(), cancelled);
    }

    fn rest_with_limit(&self, limit: &dyn Fn() -> u32, cancelled: &dyn Fn() -> bool) {
        let initial = limit();
        let (Some(before), Some(after)) = (self.cpu, process_cpu_time()) else {
            // Without a CPU clock fall back to the wall time of the work (single-threaded upper bound).
            self.rest_for_duration(
                rest_for(self.wall.elapsed(), self.wall.elapsed(), initial),
                limit,
                cancelled,
            );
            return;
        };
        let rest = rest_for(after.saturating_sub(before), self.wall.elapsed(), initial);
        self.rest_for_duration(rest, limit, cancelled);
    }

    fn rest_for_duration(&self, rest: Duration, limit: &dyn Fn() -> u32, cancelled: &dyn Fn() -> bool) {
        let deadline = Instant::now() + rest;
        while Instant::now() < deadline {
            if cancelled() || limit() == 0 {
                return;
            }
            std::thread::sleep(REST_SLICE.min(deadline.saturating_duration_since(Instant::now())));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicBool;

    fn spin_cpu(duration: Duration) {
        let start = process_cpu_time().unwrap();
        let mut accumulator = 0u64;
        while process_cpu_time().unwrap().saturating_sub(start) < duration {
            accumulator = accumulator.wrapping_add(1);
            std::hint::black_box(accumulator);
        }
    }

    #[test]
    fn rest_keeps_the_duty_cycle_at_or_below_the_limit() {
        // 10 s of CPU in 10 s of wall time at a 50% budget needs 10 s of rest.
        assert_eq!(
            rest_for(Duration::from_secs(10), Duration::from_secs(10), 50),
            Duration::from_secs(10)
        );
        // At 80% the same work needs 2.5 s.
        assert_eq!(
            rest_for(Duration::from_secs(10), Duration::from_secs(10), 80),
            Duration::from_millis(2500)
        );
        // Work that already took long enough (idle waits inside) needs no rest.
        assert_eq!(
            rest_for(Duration::from_secs(5), Duration::from_secs(20), 50),
            Duration::ZERO
        );
        // Unlimited (foreground) never rests; a huge burst is capped.
        assert_eq!(rest_for(Duration::from_secs(10), Duration::from_secs(10), 0), Duration::ZERO);
        assert_eq!(rest_for(Duration::from_secs(1000), Duration::ZERO, 10), MAXIMUM_REST);
        // The resulting duty cycle is within the limit for a range of limits.
        for limit in [20u32, 40, 50, 60, 80] {
            let cpu = Duration::from_millis(900);
            let wall = Duration::from_millis(1000);
            let total = wall + rest_for(cpu, wall, limit);
            assert!(cpu.as_secs_f64() / total.as_secs_f64() <= f64::from(limit) / 100.0 + 1e-9, "{limit}");
        }
    }

    #[test]
    fn a_backgrounded_unit_of_work_rests_so_the_cpu_share_stays_under_the_limit() {
        let cycle = DutyCycle::begin();
        spin_cpu(Duration::from_millis(200));
        let started = Instant::now();
        cycle.rest_with_limit(&|| 50, &|| false);
        let total_wall = cycle.wall.elapsed();
        let cpu_used = process_cpu_time().unwrap().saturating_sub(cycle.cpu.unwrap());
        assert!(started.elapsed() >= Duration::from_millis(150), "rested {:?}", started.elapsed());
        assert!(
            cpu_used.as_secs_f64() / total_wall.as_secs_f64() <= 0.55,
            "duty cycle {:.2}",
            cpu_used.as_secs_f64() / total_wall.as_secs_f64()
        );
    }

    #[test]
    fn the_foreground_is_not_slowed_and_cancellation_ends_a_rest_at_once() {
        let cycle = DutyCycle::begin();
        spin_cpu(Duration::from_millis(100));
        let started = Instant::now();
        cycle.rest_with_limit(&|| 0, &|| false);
        assert!(started.elapsed() < Duration::from_millis(40), "foreground rested {:?}", started.elapsed());
        let backgrounded = DutyCycle::begin();
        spin_cpu(Duration::from_millis(400));
        let started = Instant::now();
        let cancelled = AtomicBool::new(true);
        backgrounded.rest_with_limit(&|| 10, &|| cancelled.load(Ordering::Relaxed));
        assert!(started.elapsed() < Duration::from_millis(60), "cancelled rest took {:?}", started.elapsed());
    }

    #[test]
    fn coming_back_to_the_foreground_cuts_a_rest_short() {
        let cycle = DutyCycle::begin();
        spin_cpu(Duration::from_millis(300));
        let limit = AtomicU32::new(10);
        let started = Instant::now();
        std::thread::scope(|scope| {
            scope.spawn(|| {
                std::thread::sleep(Duration::from_millis(120));
                limit.store(0, Ordering::Relaxed);
            });
            cycle.rest_with_limit(&|| limit.load(Ordering::Relaxed), &|| false);
        });
        assert!(started.elapsed() < Duration::from_millis(400), "rest lasted {:?}", started.elapsed());
    }

    #[test]
    fn the_global_limit_is_clamped_and_lifted_with_zero() {
        set_background_cpu_limit_percent(250);
        assert_eq!(background_cpu_limit_percent(), 100);
        set_background_cpu_limit_percent(50);
        assert_eq!(background_cpu_limit_percent(), 50);
        set_background_cpu_limit_percent(0);
        assert_eq!(background_cpu_limit_percent(), 0);
    }
}
