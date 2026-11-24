---
name: device-test
description: Run a physical iPhone test with the preflight checks first, and report red-to-green evidence or one human-only blocker.
---

# Physical iPhone test

Read `docs/agents/device-supervised-runs.md` (preflight and failure signatures) and
the execution policy. Then:

1. Preflight: send Pietro one message listing every human-only step still needed
   (UI Automation, Auto-Lock Never, Mirroring closed, trust). Do not build until
   the answer is known or the steps are confirmed as already done.
2. Build while the phone stays locked through `scripts/device-workflow.sh` or
   `build-for-testing`; rebuild the FFI if Rust changed.
3. Gate the run with `xcrun devicectl device info lockState`; ask for one unlock
   only when the run step is next.
4. Run the focused case (`-only-testing`). On failure, match the failure-signature
   table, apply the known fix and retry; add a row for any new signature.
5. Report the red and green results with log excerpts and the result bundle path,
   close the app on the device, and never leave the phone idle without saying why.
