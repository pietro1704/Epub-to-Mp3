# Scoped Simulator conversion result

Continuing the full quality/performance goal; this closes only the bounded
Simulator conversion evidence slice, not reader, warm-open or cross-client gates.

Evidence: `.reports/simulator-conversion-DC6480EE-AA44-4A55-8421-B21D3AA96896`
contains specification, native report and retained XCTest attachment. Result:
`.reports/simulator-smoke-28B96974-6025-4312-AAB0-96EF5D1659A6/tests.xcresult`.
One executed benchmark passed, zero failures/skips, 213.031 s native test interval.
Existing Swift Debug app with explicitly bundled optimized Rust Release artifact;
Intel SE second-generation Simulator, iOS 16.0 (20A360), CLI Xcode 16.4 controller.
No new build during execution, no Python, physical phone or CI/PR monitoring.

| Input / inclusive zero-based range | Characters | Conversion interval | Validated audio | First whole-chapter delivery |
| --- | ---: | ---: | ---: | ---: |
| Christie 6–7 | 5,778 | 6.0183 s | 349.248 s, 2 chapters | 2.8305 s, source 6 |
| LOTR 8–9 | 112,357 | 199.4277 s | 7,007.16 s, 2 chapters | 121.5554 s, source 8 |

Exact SHA-verified originals from the prior requested benchmark; two chapters
per book, fresh UUID jobs and no audio reuse. All published chapter callbacks
were accepted (empty rejection arrays), native AVFoundation checks validated
positive duration/playability and exact finished snapshot scope. No larger range
or whole-book synthesis. Native owned-output/input-copy cleanup reported no errors.

Historical unoptimized Simulator run used the same EPUB/ranges but failed LOTR
delivery validation: Christie 31.6898 s, LOTR conversion return 591.3819 s. Both
Rust profile and Swift path decoding/diagnostics changed since then; network also
varied (current LOTR one retry, earlier zero). Do not attribute the complete timing
difference to one change or call the failed run a fully accepted baseline.
No matched physical-phone speedup claim. Provider voice/language snapshot fields
remain unmeasured; logs identify Edge. First whole-chapter delivery is not acoustic
playback or first segment availability; footprint observations are points, not peak
or controlled before/after memory measurements.

Remaining: real-book reader gesture gate, 200 ms warm/relaunch opening, first
audible/seek measurements, controlled shared-Rust throughput and pending Arch
Flutter verification. Preserve those acceptance criteria without relaxing thresholds.
