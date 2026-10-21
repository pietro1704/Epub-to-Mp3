# Apple native client

The Apple client lives in [EpubToMp3/](EpubToMp3/README.md). Its application UI
uses UIKit on iOS/iPadOS and AppKit on macOS. Both use embedded Rust
`converter-core`/`converter-ffi` for conversion. Python/FastAPI and the standalone
Rust HTTP server are compatibility surfaces, not Apple conversion prerequisites.

Start with the library/import, reader and playback flow. Shared behavior belongs
in Rust; native services adapt local files, platform voice APIs, media controls
and UI. Use [runtime navigation](../docs/agents/runtime-navigation.md) for current
entry points and [CONTEXT.md](../CONTEXT.md) plus relevant ADRs for domain terms.
The former slice-1/2/3 UI trees, wire recaps and passing-test transcripts are
historical snapshots, not current feature or acceptance reports.

Before building or opening an app, read
[execution policy](../docs/agents/execution-policy.md) and
[macOS validation](../docs/agents/macos-validation.md). Prefer inspection or
packaging against a matching existing artifact when that answers the task.
All Mac compilation uses guarded project tasks; preserve books, model files,
application data and evidence. Simulator execution is quarantined, including
existing artifacts and alternate launchers.

For reader/pagination/chrome/player changes, read
[EpubToMp3/AGENTS.md](EpubToMp3/AGENTS.md) and use the native-reader-regression
skill. Required iPhone SE1/iOS 15.5 acceptance remains pending while quarantined;
a physical device or newer runtime does not replace it. Source checks and host
fixtures do not establish native rendering, playback or conversion success.

Use `project.yml` as the Xcode project definition. Inspect `mise.toml` for current
`xcode:generate`, `mac:validate` and guarded build tasks rather than creating a
new Xcode scaffold or invoking a compiler directly. Building, launching and
visible-app acceptance are separate actions; document what was actually observed.
