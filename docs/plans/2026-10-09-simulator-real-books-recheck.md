# Actual-book Simulator conversion recheck

## Scope and runtime

User requested resuming the quality/performance goal after confirming app launch.
Reuse the built native Swift app with embedded release-profile Rust; no rebuild,
external backend, Python, physical device or CI/PR monitoring.
iPhone SE (2nd generation), iOS 16.0 (20A360), x86_64 Simulator
`381DBE17-FFAB-4A2E-B35F-AB9FEC92C14E`, Xcode 16.4 test controller.

Inputs were SHA-256 checked against the original imported EPUBs before staging
isolated copies. Chapter indices are zero-based and inclusive:

- The Lord of the Rings: 8–9, SHA-256
  `3e1c676b270dfa3fe555eba4d0cb993486e9f00facb7cc92eef250e64efb7c9e`.
- E não sobrou nenhum: 6–7, SHA-256
  `55417053355de78768a0823d3cd203fde5c80bd8026407ffb5766b3f730d11da`.

## Executed evidence

`mise run ios:simulator:smoke:test`, with the explicit Simulator UUID,
`IOS_TESTS=EpubToMp3Tests/DeviceConversionBenchmarkTests/testOptInDeviceConversionBenchmark`,
isolated `IOS_SIMULATOR_XCTESTRUN_PATH`, and 900-second operation/startup budgets.
The first attempt exited 75 before synthesis because host load exceeded the guard.
The same staged run was resumed after load fell; no concurrent heavy jobs or
resource-guard bypass. Test interval: 198.939 seconds.

Run ID: `290BEB28-A939-433D-AAEC-99A4CBC80BE4`.
Result bundle: `.reports/simulator-smoke-35C92954-3AA6-4C11-A805-B5F2E6C7ADA1/tests.xcresult`.
`xcresulttool get test-results summary`: exactly 1 passed, 0 failed, 0 skipped.
Permanent native report exported under
`.reports/simulator-conversion-290BEB28-A939-433D-AAEC-99A4CBC80BE4/attachments/`.

| Book | Chapters completed | Conversion seconds | First complete chapter delivery | Audio seconds |
| --- | --- | --- | --- | --- |
| Christie | 2/2 (6–7) | 5.286 | 2.511 | 349.248 |
| LOTR | 2/2 (8–9) | 186.526 | 118.979 | 7009.584 |

Both cases had zero rejected deliveries, retry/pressure events and throttles.
Fresh job IDs and `audio=false` establish no audio reuse. Parsed text reuse remains
unmeasured. Native checks validated MP3 artifacts and AVFoundation playability.
The report has no conversion or app-owned cleanup errors. Host staging is retained;
do not infer complete Simulator temporary-directory cleanup.

## Limits and remaining acceptance

The prior same-range optimized run measured Christie 6.018 s and LOTR 199.428 s.
This is a repeatability observation, not proof that the new chapter snapshot store
improved conversion: that storage-only slice is not integrated into controllers.
Provider latency varies; provider/model snapshot fields remain null although logs
identify Edge. First complete chapter delivery is not first audible playback.
Process footprint samples are not peak memory.

This run does not validate chapter seek/navigation in the UI, the unresolved
production swipe automation, Flutter parity, or the 200 ms across-relaunch reader
opening budget. Keep the overall goal and APP-20261009-23 open for those seams.
Original imported books, installed models and existing downloads were not changed.

## Latest requested repeat: 8A081C2E

After the user again confirmed launch and requested both books, reused the native
build and the same hash-checked inputs/ranges on the same iOS 16 SE Simulator.
Run `8A081C2E-7F4D-4433-A284-685C9A7579BB` passed exactly one benchmark,
zero failures and zero skips. Result:
`.reports/simulator-smoke-135A4598-E633-4CFD-A524-824E81A84F52/tests.xcresult`.
Exported native attachment:
`.reports/simulator-conversion-8A081C2E-7F4D-4433-A284-685C9A7579BB/attachments/EC6C0756-4954-4E6F-9468-C20B2525C6D8.json`.

| Book | Completed | Synthesis seconds | First published chapter seconds | Audio seconds | Retries |
| --- | --- | --- | --- | --- | --- |
| Christie | 2/2 (6–7) | 21.643 | 2.348 | 349.248 | 0 |
| LOTR | 2/2 (8–9) | 252.736 | 62.612 | 7002.600 | 1 |

Both cases produced valid playable MP3 artifacts with fresh job IDs and no audio
reuse, no rejected chapter deliveries, no throttles and no reported errors.
Parsed-text reuse remains unmeasured. Test-controller interval was 285.388 s;
this is not synthesis time. LOTR logs show `chunk_limit=2048`,
`max_in_flight=1`, and a total of 29 chunks for its second selected chapter.
Total synthesis worsened versus the preceding repeat; first LOTR chapter delivery
improved. Neither observation establishes a causal regression or optimization:
provider fields remain null, remote service latency varies, and no controlled
code change was measured. Point memory samples are not peak memory. Originals,
models and downloads were preserved; isolated staging/evidence was retained.
The overall goal remains active, including configuration, concurrency, reader
navigation, audible playback and the failing relaunch latency acceptance.
