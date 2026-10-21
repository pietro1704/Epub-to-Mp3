# Snapshot reference directory

This directory is retained for snapshot evidence. The current test tree does not
contain the former `SnapshotConfig.swift`, `ReaderSnapshotTests`,
`PlayerSnapshotTests` or `LibrarySnapshotTests` described by the old guide.
Do not assume a configured device matrix, `record` switch, precision value or
per-PR snapshot gate exists without checking the actual tests and project.

For an authorized snapshot implementation/update, define the native rendering
seam, deterministic content, fonts, scale, traits, runtime/toolchain and image
identity. Review newly recorded references before accepting them; a bad baseline
can preserve clipping or incorrect layout. Keep record mode off in delivered
tests, inspect intentional image diffs and report the actual assertion tolerance.
A percentage pixel threshold alone cannot guarantee complete glyph visibility.

Native reader regressions require behavior tests and visible-app acceptance
under [the reader contract](../../AGENTS.md) and the native-reader-regression
skill. Use the current guarded tasks and
[execution policy](../../../../docs/agents/execution-policy.md).
Direct `xcodebuild test`/Simulator recipes are not an execution path: Simulator
execution is quarantined, and required SE1/iOS 15.5 acceptance stays pending.
Compiling a target or inspecting a PNG cannot substitute for that acceptance.
