# App delivery backlog

## CI-20261016-OFFLINE-AUDIO — Separate decoded-audio regressions from live Edge availability

- [ ] Replace implicit network audio fixtures with deterministic local PCM/MP3 checks covering real decoding, title/body pause, sample rate and retained active audio.
- [ ] Keep actual Edge synthesis behind explicit `RUN_LIVE_EDGE_AUDIO_TESTS=1`; HTTP 403, timeout and empty payload remain fatal in the manual-only GitHub live workflow.
- [ ] Verify default collection avoids network, disabled synthesis never imports/calls Edge, explicit opt-in is literal, and live provider errors propagate. Execute checks only on GitHub under the current user instruction.
- Owner: crash_workflow_audit specialist; branch `feature/ci-offline-audio-fixtures`. Baseline: master CI run `38862909247`, Python job `116849117822` has one Edge fingerprint failure and three audio-fixture setup errors from HTTP 403. No production/provider code changes or live provider probes.
- Status: implementation pending GitHub verification; no local tests or syntax checks executed. Preserve user books/models and unrelated work.

