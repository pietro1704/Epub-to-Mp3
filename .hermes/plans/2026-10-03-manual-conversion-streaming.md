# Feature: separate streaming playback from manual conversion

- Type: enhancement/bug
- State: implementing
- Scope: Flutter reader/player flow for imported EPUBs.
- Books for device verification:
  - `E não sobrou nenhum` — Portuguese, expected locale `pt-BR`.
  - `The Lord of the Rings` — English, expected locale `en-US`.
- Desired behavior:
  - Play never starts conversion when no audio queue exists.
  - Conversion is an explicit manual action in the reader.
  - Manual conversion detects the book language and converts chapter-by-chapter.
  - Generated chapters are appended to the player queue for progressive playback.
  - Conversion does not auto-play; Play remains the separate playback action.
- Acceptance criteria:
  - No `playbackRequestProvider` conversion callback is installed by `BookOpenScreen`.
  - Reader exposes an explicit Convert action.
  - First available converted chapter can be played from the queue.
  - PT-BR and English fixtures select distinct correct locales.
  - Flutter tests/analyze/build pass and both flows are exercised on the real Android device.

## Execution Log

### 2026-10-03 — triage

- Evidence: `BookOpenScreen.initState` assigned `_startConversion` to `playbackRequestProvider`; `MiniPlayerBar` invoked that callback when the queue was empty.
- Evidence: `_startLocalConversion` already detects the full-book locale with `SpeechTextPolicy.detectLocale` and appends chapter audio to the queue.
- Decision: preserve the existing chapter-by-chapter conversion implementation, remove its Play trigger and expose it as an explicit reader action.
- Next step: patch the reader/player boundary and add regression tests for the separation.

### 2026-10-03 — implementation and real-device verification

- Changed `BookOpenScreen`: removed the playback-to-conversion callback; added explicit `Convert` action; removed automatic `player.play()` from local conversion/restoration.
- Focused tests: reader/converter/speech tests passed; speech tests verify English Tolkien text and Brazilian Portuguese text.
- Full Flutter suite: 367 tests passed; `flutter analyze` passed; debug APK built and installed successfully.
- Real device: Samsung `52008714b40355ad` launched the app successfully; screenshot showed the Portuguese book, explicit `Converter` button, separate Play triangle, and no visible error.
- Portuguese flow: manual Convert tap produced logs `verified book locale=pt-BR`, `chapters=113`, and requested Edge for chapter 0. No playback auto-started.
- English flow: `The Lord of the Rings` opened and rendered English text; manual Convert tap produced `verified book locale=en-US`, `chapters=98`, and requested Edge for chapter 0. No playback auto-started.
- Separation proof: pressing Play with an empty queue produced no conversion/start logs and no crash.
- Limitation: Edge request remained pending after the first chapter request on this device/network, so generated MP3 playback/streaming of audio was not completed in this run. The app-side separation and locale routing are verified; Edge transport remains the blocker for audible output.
- Status: partially verified; implementation and device UI/locale/separation checks pass, audible Edge streaming remains blocked by the pending transport request.
- Next step: verify Piper synthesis with the installed `pt_BR-edresson-low` model and then install/verify `en_US-lessac-low`; the current app conversion path still needs explicit native Piper selection after Edge failure.

### 2026-10-04 — Persisted Android TTS audio attempt

- Added Android `TextToSpeech.synthesizeToFile` bridge with locale selection and utterance completion callbacks.
- Connected Edge failure path to synthesize a local file, read it back, and feed it through the existing chapter queue path.
- `flutter analyze`, focused tests, and APK build passed.
- Real Samsung device: Edge still returned HTTP 403. Google TTS initialized and selected `en-US`, but `synthesizeToFile` did not complete within the verification window and no `chapter_*.mp3` appeared in the app output directory.
- Device logs showed Google TTS model/download activity and native regex errors; no completed utterance callback or playable output was observed.
- Status: direct Android TTS speech fallback was previously verified; persisted local audio fallback is implemented but not yet verified. Do not claim MP3 streaming complete.

### 2026-10-04 — Edge protocol attempt and Android fallback

- Attempt 1 updated `edge_web_tts.dart` to current edge-tts transport conventions: randomized `muid`, current Chromium 143 headers, `Sec-WebSocket-Version`, and one generated `Sec-MS-GEC` value per request.
- Attempt 1 validation: `mise run flutter:analyze`, focused Flutter tests, and debug APK build passed; real device still returned HTTP 403 from the Edge WebSocket.
- Attempt 2 implemented explicit Android TTS fallback in `AndroidEmbeddedConverter.speakFallback()` and `BookOpenScreen`.
- Real device evidence with `The Lord of the Rings`: locale verified as `en-US`; Edge failed with HTTP 403; fallback selected Google TTS, selected locale `en-US`, and continued through subsequent chapters. UI remained open, Converter stayed separate from Play, and no crash occurred.
- Real device evidence from Android TTS listed both `pt-BR` and `en-US` voices; locale selection logged `selected locale=en-US`.
- Limitation: fallback speaks text directly through Android TTS and marks the chapter as failed; it does not create an MP3 or add an item to the audio queue. The original streaming-to-MP3 objective therefore remains incomplete when Edge is rejected.
- Status: Edge path blocked by remote HTTP 403; direct offline speech fallback verified on device.

### 2026-10-03 — Edge transport diagnosis on real device

- Device network: Wi-Fi connected and validated; device ping to `speech.platform.bing.com` succeeded.
- App evidence: manual Tolkien conversion selected `en-US` and reached `requesting Edge chapter index=0`.
- Root cause: Edge WebSocket returned HTTP `403` during handshake: `WebSocketChannelException: ... speech.platform.bing.com ... was not upgraded to websocket, HTTP status code: 403`.
- Conclusion: the previous pending request was an external Edge protocol rejection, not a player queue or device connectivity failure.
- Status: blocked on Edge transport compatibility. No audible streaming claim.
- Decision needed: update the Edge WebSocket token/version protocol, or explicitly authorize a local Android TTS fallback for audible streaming when Edge rejects the request.
