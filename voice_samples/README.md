# Voice samples

Optional sample audio lives under `voice_samples/edge/` and
`voice_samples/piper/`. Samples are fixtures/previews, not proof of the active
voice, installed model catalog or successful conversion. They are not required
for normal conversion.

Piper `pt_BR-faber-medium` is primary. Installed system TTS is the default
fallback where supported, preferring Luciana for Brazilian Portuguese on Apple
when available; report the actual backend/voice. Explicit job choices win.
Model installation requires an explicit action and must preserve existing models.

Sample generation is separate from inspecting this directory. Use an already
installed provider/model only within the authorized task and record model/voice,
text, output format and provenance. Edge/cloud synthesis requires explicit consent;
a sample command is not consent. Audible checks identify deliberate fixture audio
before playback and follow [execution policy](../docs/agents/execution-policy.md).

For API preview/catalog work, inspect actual routes and client adapters rather
than treating old `GET /api/voices` or `GET /api/voice-preview` behavior as the
universal catalog. Browser native speech is listening-only; downloadable MP3
requires Piper. Retained samples do not override those capability boundaries.
