---
name: device-test
description: Run a physical iPhone test with the preflight checks first, and report red-to-green evidence or one human-only blocker.
---

# Physical iPhone test

Read `docs/agents/device-supervised-runs.md` (preflight and failure signatures) and
the execution policy. Then:

1. Preflight: send Pietro one message listing every one-time human-only setup still
   needed (UI Automation, Auto-Lock Never, Mirroring closed, trust). Do not ask him
   to confirm an unlock.
2. Build and run through `scripts/device-workflow.sh`; rebuild the FFI if Rust
   changed. The build does not depend on the phone.
3. Let the workflow wait for the phone (`WAITING_FOR_UNLOCK`,
   `WAITING_FOR_FOREGROUND`, 30 min each). Do not launch by hand around those waits.
4. Run the focused case (`-only-testing`). On failure, match the failure-signature
   table, apply the known fix and retry; add a row for any new signature.
5. Report the red and green results with log excerpts and the result bundle path,
   close the app on the device, and never leave the phone idle without saying why.
