# Piper high terminal comparison

Date: 2026-10-14. Hardware: Intel Core i5-8259U MacBook Pro, 8 GiB RAM, built-in speakers and microphone. This is a native Mac CLI measurement, not an iPhone or production-app benchmark. No product provider configuration was changed.

The same 116-character Portuguese short fixture from the previous benchmark was synthesized by Faber medium, Miro high and Dii high. Runtime: prebuilt sherpa-onnx 1.13.8 macOS x64 shared CLI, FP32 checkpoints, two CPU threads. Three fresh CLI processes per voice; command time includes process startup, model loading, synthesis and WAV saving. No local synthesized-audio cache was reused. OS page-cache coldness was not controlled.

| Voice | Median command to complete WAV | Native CLI maximum peak RSS across three runs | ONNX bytes |
| --- | ---: | ---: | ---: |
| Faber medium | 2.002 s | 177.5 MiB | 63,201,457 |
| Miro high | 2.259 s | 181.8 MiB | 63,511,201 |
| Dii high | 2.258 s | 180.8 MiB | 63,511,201 |

All nine WAV outputs passed full FFmpeg decoding, positive duration and a non-silent signal check. The two high packages were approximately 13% slower than Faber for this fixture, with similar weight size and host memory. The publisher's `high` names are identifiers, not a measured guarantee of better sound or proof of a larger architecture. Their JSON configurations describe 22,050 Hz audio and `quality=training`. They are different voices, not high upgrades of Faber.

Miro high and Dii high were then audibly played in that order through a terminal-driven AVAudioEngine player. No GUI app was launched for this round, honoring the user's terminal request. Existing system volume was retained. Host-clock timestamps recorded the play call, first non-zero rendered audio, and microphone threshold crossing. No ambient microphone PCM was saved.

| Voice | Command to first non-zero render | Render plus reported downstream hardware latency | Command to microphone detection |
| --- | ---: | ---: | ---: |
| Miro high | 54.66 ms | 55.06 ms | 164.06 ms |
| Dii high | 86.95 ms | 87.35 ms | 231.07 ms |

These playback values use **already synthesized WAV files**, with the engine running and the files scheduled before the play command. They exclude synthesis, player launch and first engine initialization. Microphone detection is an acoustic **estimate**: RMS must exceed `max(0.003, baseline p95 × 2)` for three consecutive 256-frame windows at 48 kHz. Voice attacks and ambient noise affect the threshold crossing; it is not exact first perceptible speech. One playback per voice does not establish a latency distribution. The earlier Faber audition used a different threshold and is not a controlled acoustic comparison with these two runs. Do not add separate-run synthesis and playback medians and call that a measured end-to-end latency.

Evidence: `.reports/piper-high/20261014/synthesis-report.json`, nine generated WAVs and their synthesis/decode logs, `playback-report.json`, `playback.log`, and the terminal player source. Native synthesis ran through `mise run tts:piper-high:benchmark` under the shared resource lease. The terminal player also held the lease. No Python runtime, model export or product rebuild was required.

Model packages came from the [sherpa TTS release](https://github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models), using the exact `vits-piper-pt_BR-{faber-medium,miro-high,dii-high}.tar.bz2` names. Miro references an OpenVoiceOS checkpoint; [Miro metadata](https://huggingface.co/csukuangfj/vits-piper-pt_BR-miro-high) and [Dii metadata](https://huggingface.co/csukuangfj/vits-piper-pt_BR-dii-high) remain useful for checking origins and licenses before product integration. Output timing uses Apple's [AVAudioTime host clock](https://developer.apple.com/documentation/avfaudio/avaudiotime) and [hardware presentation latency](https://developer.apple.com/documentation/avfaudio/avaudioionode/presentationlatency).

Cleanup removed 541,273,587 bytes across 1,117 files and verified the isolated download tree absent. Pre-existing repository models and generated comparison audio are preserved. The receipt is saved as `.reports/piper-high/20261014/cleanup.json`; temporary runtime-release metadata was also removed.
