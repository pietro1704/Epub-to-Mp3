# Getting started

Choose the client first. Read [Architecture](Architecture.md), then inspect the
current root `mise.toml`, relevant manifest and
[execution policy](../../agents/execution-policy.md). Tool versions belong to
those manifests, not a duplicated Python-first installation list.

- Apple: follow the [native guide](../../../ios/EpubToMp3/README.md) and
  [macOS validation](../../agents/macos-validation.md), reusing matching artifacts.
- Browser: follow [web/README.md](../../../web/README.md); with existing
  dependencies, `mise exec -- npm run dev` in `web/` starts Vite. Rust/WASM and
  TTS assets must match the current source.
- CLI: [CLI and Web](CLI-and-Web.md) describes the Rust `convert` task.
- Flutter: follow [flutter_app/README.md](../../../flutter_app/README.md) and
  target-platform prerequisites; Android work is currently paused.

Model installation is explicit. Select/install Piper `pt_BR-faber-medium` through
the supported client action when desired; preserve other models. A missing model
is not permission to download one, call Edge or install a paid provider silently.
Browser storage/capabilities and native runtime dependencies need actual checks.

An available task is not evidence that setup, conversion or a release works.
Record the exact revision, artifact and observed result. Local Python/Ruff checks
remain deferred to CI, and Simulator execution remains quarantined. Package,
compile, launch and visible-app acceptance are separate stages.
