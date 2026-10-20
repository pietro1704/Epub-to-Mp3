# Piper primary and native fallback: implementation audit

Date: 2026-10-16. Scope: inspected current local working tree, including existing
uncommitted changes; not a claim about master, shipped binaries or live behavior.

## Accepted policy

The canonical policy is in `../../CLAUDE.md`, under Runtime. The user chose
Piper Faber medium as the default primary for its preferred AI narration quality,
with installed native speech as fallback across all app platforms. Apple should
prefer installed Luciana for pt-BR. This audit records gaps, not implementation.

## Source findings

| Platform | Default primary | Native fallback implementation | Conforms fully? |
| --- | --- | --- | --- |
| iOS | Piper Faber medium | Apple PCM callback registered, but secondary defaults to nil; system voice is not offered by AudioEnginePreference. Voice selection prefers compact locale-compatible voices, without preferring Luciana. | No |
| macOS native | Piper Faber medium | Shares Apple preferences and platform synthesis adapter; same default-secondary and Luciana-selection gaps. | No |
| Android Flutter | Piper Faber medium | Rust JNI registers AndroidPlatformSpeech; Kotlin PlatformSpeechProvider synthesizes WAV with an installed offline locale-compatible voice. Dart default secondary is null. | No |
| Linux Flutter | Piper Faber medium | Desktop FFI worker does not register a platform speech callback; no native fallback wired in the inspected desktop adapter. Default secondary is null. | No |
| Windows Flutter | Piper Faber medium | Same desktop FFI gap as Linux. Default secondary is null. | No |
| Web browser | Piper Faber medium | Browser runtime supports Piper only; non-Piper synthesis is rejected. Default secondary is null; no browser speechSynthesis integration found in web/src. | No |

## Evidence

- Shared defaults: `crates/converter-core/src/tts_preferences.rs`:
  TtsSelection defaults to Piper/Faber; derived TtsPreferences default has no
  secondary. Existing test `defaults_are_offline_faber` asserts secondary is None.
  Validation accepts system but rejects a voice identifier for it.
- Execution: `crates/converter-core/src/worker.rs`, synthesize branch for system
  requires a registered PlatformTts adapter. Fallback is attempted only when
  preferences.secondary exists. SegmentPolicy stops after three consecutive
  primary failures, so current fallback does not sustain an unavailable primary
  for an entire book. A future implementation must explicitly resolve that
  acceptance case without silently changing the established retry policy.
- Apple: `ios/EpubToMp3/EpubToMp3/Shared/Configuration/AppSettings.swift`,
  `Features/Conversion/Services/AudioEnginePreference.swift`,
  `Features/Conversion/Services/ConverterFFIAdapter.swift`, and
  `Features/Conversion/Services/PlatformSpeechSynthesizer.swift`.
  Settings retain explicitly persisted engine values; the available engine enum
  contains Piper and Edge. Registering the callback does not enable fallback.
- Android: `crates/converter-ffi/src/lib.rs` registers AndroidPlatformSpeech on
  the JNI conversion session; Kotlin adapter in
  `flutter_app/android/app/src/main/kotlin/com/pietrocode/epubtomp3/flutter_app/PlatformSpeechProvider.kt`.
  Defaults: `flutter_app/lib/models/tts_preferences.dart`. The secondary:null in
  `_legacyConversionOptions` in `flutter_app/lib/services/local_conversion_job.dart`
  preserves a legacy job's recorded selection; it is not the default for new jobs
  and must not be replaced by a newly introduced fallback during resume.
- Desktop: `flutter_app/lib/services/desktop_embedded_converter.dart` opens a
  session and invokes controlled/streaming conversion without installing the
  platform TTS callback. `converter-ffi` sessions start with platform_tts:None.
- Browser: `web/src/services/TtsPreferences.ts` defaults secondary:null;
  `web/src/services/BrowserConversionClient.ts` runtime.synthesize rejects
  selection.engine other than piper and requires explicit Faber installation.
  A browser native playback fallback must account for the existing conversion
  contract requiring encoded audio artifacts; speech playback alone is not
  evidence of an exportable WAV/MP3 implementation.

## Verification limits and follow-up

No runtime changes, tests, compilation, playback, devices or Simulator were
executed. No acoustic voice-quality judgment is established by this audit.
Installed voice availability and saved user preferences remain unverified.
Implementation follow-up must cover successful primary synthesis, native
fallback, missing model/voice, cancellation, locale identity and retry behavior
at the exercised runtime. The Simulator quarantine remains in force.
