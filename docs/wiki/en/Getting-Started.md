# Getting started

Choose the client first. Read [Architecture](Architecture.md), then inspect the
current root `mise.toml`, relevant manifest and
[execution policy](../../agents/execution-policy.md). Tool versions belong to
those manifests, not a duplicated installation list.

- Apple: follow the [native guide](../../../ios/EpubToMp3/README.md) and
  [macOS validation](../../agents/macos-validation.md), reusing matching artifacts.
- Browser: follow the [Rails web README](../../../ruby_app/rails_gateway/README.md);
  `mise run rails:web:runtime-build` generates the Rust/WASM and TTS runtime tree
  and `mise run rails:web:test` runs the tests. The tree must match the current
  source; it is never committed.
- CLI: [CLI and Web](CLI-and-Web.md) describes the Rust `convert` task.
- Flutter: follow [flutter_app/README.md](../../../flutter_app/README.md) and
  target-platform prerequisites; Android work is currently paused.

Model installation is explicit. Select/install Piper `pt_BR-faber-medium` through
the supported client action when desired; preserve other models. A missing model
is not permission to download one, call Edge or install a paid provider silently.
Browser storage/capabilities and native runtime dependencies need actual checks.

An available task is not evidence that setup, conversion or a release works.
Record the exact revision, artifact and observed result. Simulator execution
has no host guard since 2026-11-22. Package,
compile, launch and visible-app acceptance are separate stages.
