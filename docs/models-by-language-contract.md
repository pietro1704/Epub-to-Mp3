# Models by language — Rust/FFI contract (SETTINGS-MODELS-BY-LANGUAGE)

Status: implemented (Rust core `language_model_resolution`, FFI `language_model_boundary`); proposed by epub-apple (shared-Rust owner), 2026-11-23, for Arch/Flutter/WASM parity.
Rust owns the resolution; clients own only the persisted choice and the presentation.

## Principles
- One persisted choice per book language; a book in any language plays without asking, or the user is sent to the Models screen.
- Model installation stays an explicit user action (existing installer APIs). Resolution never downloads.
- Online (Edge) is never chosen implicitly: it needs the online consent (`allow_online_fallback`, refused otherwise by `TtsPreferences::validate`, PR #1344).
- A per-job selection (manual override) stays authoritative: it bypasses this resolution entirely.
- The installed system voice is a local option of its language and a fallback only when the user's `allow_automatic_system_voice_fallback` setting is on (default on).
- No "uncertain" book language state: clients pass the language Rust confirmed (`analyze_book.confirmed`, incl. the 1-inconclusive rule of PR #1333) or the one the user corrected.

## 1. Catalog by language (reuse, no change)
`converter_tts_catalog_json_v3(language, platform, android_api, architecture, os_version, model_root)` already returns, for ONE language, every entry with `identity`, `presentation`, `distribution.installable`, `installation`, `compatibility`, `readiness` and `selection.selectable`. The Models screen calls it once per language of the list below and groups entries as local (provider `piper`/`system`/other offline) vs online (provider `edge`), per model and quality (`presentation`). Rows with `installation != installed` or `selection.selectable == false` are dimmed, EXCEPT the installed system voice (provider `system`, listed as a local option of its language): it is never dimmed, because it is always available, and it only becomes the automatic reserve when the user setting `allow_automatic_system_voice_fallback` (on by default) is on; tapping a dimmed installable row starts the existing install flow immediately (explicit user action) with progress.

## 2. New: catalog languages
`converter_tts_catalog_languages_json_v1(platform, android_api) -> {"schema_version":1,"languages":[{"tag":"pt","routing_tags":["pt","pt-BR"],"model_count":N}]}`.
Distinct base languages that have at least one catalog model (any provider) for that platform, sorted by tag. Display names are the client's (`Locale`). Core: `model_catalog::catalog_languages(platform, android_api)`.

## 2b. New: book language before a job
`converter_book_language_json_v1(path) -> {"schema_version":1,"declared":"en","confirmed":"pt-BR","languages":["pt-BR"],"samples_examined":8,"inconclusive_samples":0,"detector":"whatlang-0.18/book-consensus-v1"}` (core `language::analyze_book_file`). Same sampling and confirmation rule as a conversion, including PR #1333 (one inconclusive sample among unanimous ones still confirms; two or more, or any divergence, leave `confirmed` null and the client shows the language picker). Pure: reads the file (EPUB/PDF), writes nothing; blocking, so call it off the UI thread. Errors use the usual error envelope (`book not found`, `unsupported book type`). Clients pass `confirmed` (or the user's correction) as `book_language` to the resolver below.

## 3. New: language model resolution
`converter_tts_resolve_language_model_json_v1(request_json) -> response_json`
Request (`platform` is the `ModelPlatform` name, e.g. `"Macos"`, `"Ios"`, `"Android"`; `reasons` are stable codes such as `per_language_choice:model_not_installed`, `primary:model_incompatible_with_language`, `online_requires_consent`, `no_system_voice_for_language`, `automatic:no_installed_model`, `system_fallback_disabled`):
```json
{ "schema_version": 1,
  "book_language": "pt-BR",
  "per_language_choices": { "pt": { /* TtsSelection: engine, model_id, voice */ }, "en": { } },
  "primary": { /* TtsSelection or null (the user's default primary) */ },
  "allow_online_fallback": false,
  "allow_automatic_system_voice_fallback": true,
  "installed_model_ids": ["pt_BR-faber-medium"],
  "system_voices": ["pt-BR"],
  "platform": "ios", "android_api": null, "architecture": "arm64", "os_version": "26.0" }
```
Response (`status` is exhaustive):
```json
{ "schema_version": 1, "book_language": "pt-BR",
  "status": "selected | system_fallback | missing_model",
  "selection": { /* TtsSelection to use as the job's primary */ } ,
  "source": "per_language | primary | automatic | system",
  "reasons": ["..."],
  "missing": { "language": "pt", "suggested": [ { "model_id": "...", "quality": "...", "download_bytes": 0 } ] } }
```
Order (first that applies): (1) `per_language_choices[base(book_language)]` if installed, compatible with the language and, when online, `allow_online_fallback`; (2) `primary` if installed and compatible with the language; (3) the highest-ranked installed compatible local model (`model_catalog::candidates` + installed set; the existing automatic ranking, no implicit download); (4) the system voice for the language when `allow_automatic_system_voice_fallback` and it is in `system_voices` -> `system_fallback`; (5) otherwise `missing_model` with ranked installable `suggested` models and no `selection`. An online choice without consent is skipped with a reason (never selected). Pure function: no I/O, no download, no clock.

Core: new module `converter-core/src/language_model_resolution.rs` (+ unit tests), FFI boundary in a NEW file `converter-ffi/src/language_model_boundary.rs`. Wiring needs one `mod`/`pub use` pair in `converter-ffi/src/lib.rs` (a G6 file: coordinate with the Arch before editing) and the Android JNI/WASM/Flutter bindings that Arch owns.

## 4. Persistence (client side, not Rust)
Key `languageModelChoices.v1`: JSON object `{ "<base language tag>": TtsSelection }`, absent = automatic. Written only by the Models screen (explicit choice) and validated on read with the resolver (an uninstalled/incompatible stored choice is skipped, never deleted). Existing primary/secondary selections and per-job overrides are untouched. Apple: UserDefaults (isolated suite under `-uiTestIsolatedSettings` in UI tests); Flutter: its preferences store; same JSON.

## 5. Missing-model alert
`status == "missing_model"` (or the empty-state of the reader switch, READER-MODEL-SWITCH-BY-LANGUAGE) shows an alert whose action opens the Models screen focused on that language; it never starts a download by itself.

## 6. Test matrix (Rust, pure function)
per-language choice wins; uninstalled choice skipped -> primary; incompatible primary skipped -> automatic; online choice without consent skipped, with consent selected; automatic picks the best installed; system fallback only with the setting on; `missing_model` lists ranked installable suggestions and no selection; unknown language -> `missing_model`; `catalog_languages` stable and sorted. FFI: invalid JSON/schema -> error envelope like the other `*_json_v1` functions.

## 7. Delivery order
1. Rust core + FFI file + tests (epub-apple) ->
2. Apple Models screen and reader switch (epub-apple) ->
3. Flutter/WASM bindings and screens (Arch), consuming this document.
