# Configuration and performance

Provider/model policy belongs to shared Rust preferences/catalog/runtime and the
selected platform adapter. Piper `pt_BR-faber-medium` is primary. Installed native
TTS is the default fallback where supported, preferring Luciana for pt-BR on Apple.
Report the active backend/voice; retain Piper primary and retry it at bounded
recovery points. Explicit job choices remain authoritative. Edge is opt-in.

Model installation is explicit and preserves existing models. Browser native
speech can listen but cannot supply MP3 output; export requires browser Piper.
Do not infer model availability from a static voice sample or legacy API list.

Inspect `crates/converter-core/src/config.rs`, `paths.rs`, `tts_preferences.rs`,
model/runtime modules and the actual client settings before naming environment
variables or persistence paths. Legacy Python Edge concurrency overrides are not
a universal current performance profile. Saved preferences, explicit job values
and deployment environment can have different precedence; test the affected seam.

Cache is runtime-owned state: preserve usable books, models and artifacts. Avoid
unrequested cleanup or broad rebuilds. Mac compilation uses the shared lease,
one job and storage policy; web tests start with at most two workers. Hosted
resource limits and persistent mounts require deployment-specific verification.

Performance claims need comparable source/toolchain/model/input identity,
before/after measurements and known limits. A throughput number from a historical
campaign does not establish current speed or authorize a new benchmark.
Read [execution policy](../../agents/execution-policy.md) before resource work.
