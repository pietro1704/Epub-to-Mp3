---
name: deploy-verify
description: Verify an authorized native Apple change in the affected real app.
---

# Deploy and verify

Read `docs/agents/execution-policy.md`. For macOS, read
`docs/agents/macos-validation.md`; for iOS, read `ios/EpubToMp3/AGENTS.md`
and the applicable guidance in `docs/agents/runtime-navigation.md`. Use the
repository's guarded tasks and the current target identity.

Match verification to the requested outcome. Exercise the affected real app for
behavior changes; documentation and build-only work keep their scoped checks.
Retain source/build identity, commands, logs and observed acceptance evidence.

When the user owns manual validation, report acceptance as pending until their
result arrives. Follow the canonical app cleanup and device safety policy.
