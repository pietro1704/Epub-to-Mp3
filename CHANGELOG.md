# Changelog

## 2026-02-17 - Adaptive Performance & Telemetry Expansion

- Added adaptive runtime features for conversion throughput:
  - persisted best params per `engine+voice+language`
  - per-engine warmup support (opt-in)
  - adaptive pre-segment health-check interval
  - engine resource budget with dynamic capping
  - auto-engine A/B exploration in `--engine auto`
  - adaptive state checkpoint save/restore between runs
- Expanded runtime metrics:
  - `prefetch_hit_rate`
  - `ab_explorations`
  - `budget_caps_applied`
  - `adaptive_state_restores`
  - dashboard and summary output include optimization indicators
- Added CLI controls:
  - `--prefetch` / `--no-prefetch`
  - `--ab-auto` / `--no-ab-auto`
  - `--adaptive-checkpoint` / `--no-adaptive-checkpoint`
- Added benchmark tooling:
  - real benchmark script: `scripts/real_engine_benchmark.py`
  - CI benchmark baseline/regression helpers (threshold + baseline checks)
  - nightly benchmark workflow with artifact upload and regression issue alert
- Improved resume behavior coverage with E2E tests:
  - auto-engine + failure checkpoint + adaptive checkpoint resume flow
