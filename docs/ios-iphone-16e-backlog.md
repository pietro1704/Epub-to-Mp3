# iPhone 16e app backlog

Source: Pietro's reported iOS issues and approved changes, 2026-10-27.
Each behavior change uses a separate branch/PR and CI-gated automatic merge.
Implementation may continue while an earlier PR waits for CI. Native/iPhone
acceptance is deferred to the final campaign; required SE1/iOS 15.5 acceptance
remains blocked by Simulator quarantine. A merged PR is not device acceptance.

| Task | Scope | Implementation status |
| --- | --- | --- |
| IOS-01 | Background playback and iOS overlays | Merged [#975](https://github.com/pietro1704/Epub-to-Mp3/pull/975); device acceptance pending |
| IOS-02 | Expanded-player Play/Pause startup | Merged [#976](https://github.com/pietro1704/Epub-to-Mp3/pull/976); UIKit/audio acceptance pending |
| IOS-03 | Manual conversion stuck sending | Merged [#977](https://github.com/pietro1704/Epub-to-Mp3/pull/977); native conversion acceptance pending |
| IOS-04 | Piper punctuation and clause pauses | Merged [#978](https://github.com/pietro1704/Epub-to-Mp3/pull/978); audible comparison pending |
| IOS-05 | Whole-chapter timeline and remaining time | Merged [#979](https://github.com/pietro1704/Epub-to-Mp3/pull/979); native acceptance pending |
| IOS-06 | Seek into unavailable audio | Pending; preserve selected time and in-chunk offset, generate containing chunk |
| IOS-07 | Duplicate mini-player side material | Merged [#980](https://github.com/pietro1704/Epub-to-Mp3/pull/980); native appearance pending |
| IOS-08 | Expanded/mini-player animation and flicker | Merged [#981](https://github.com/pietro1704/Epub-to-Mp3/pull/981); native motion acceptance pending |
| IOS-09 | Expanded player without scrolling | Merged [#984](https://github.com/pietro1704/Epub-to-Mp3/pull/984); native fitting/accessibility acceptance pending |
| IOS-10 | Honor selected page-turn animation | Pending final native diagnosis; dispatch exists, inspect Reduce Motion, layout/fallback and outgoing snapshot |
| IOS-11 | Reader center-tap chrome animation | Merged [#982](https://github.com/pietro1704/Epub-to-Mp3/pull/982); native offset/clipping/motion acceptance pending |
| IOS-12 | Book search and rendered passage navigation | Merged [#983](https://github.com/pietro1704/Epub-to-Mp3/pull/983); UIKit acceptance pending |
| IOS-13 | Scrollable notes/internal-link previews and explicit Go | Published in [#985](https://github.com/pietro1704/Epub-to-Mp3/pull/985), CI/automatic merge pending; see [link contract](../ios/EpubToMp3/docs/reader-link-previews.md); local checks passed, native acceptance pending |
| IOS-14 | Original book fonts/styles by default | Pending rendering/embedded-font audit; preserve explicit user overrides |
| IOS-15 | Apple Books reference font catalog | Pending public availability/licensing audit; no private font copying/downloads |
| IOS-16 | Model management collapsed by default | Pending; retain selection, transfer state, errors and readiness summary |
| IOS-17 | Consolidate download removal controls | Pending; distinguish retained audio, temporary cache and models |
| IOS-18 | Compare compatible Brazilian Portuguese Piper voices | Pending research; no unsupported better-voice claim or automatic installation |
| IOS-19 | Sentence/paragraph-aware chunk sizing | Pending Piper-specific proposal; 800 characters is not a universal optimum |

## Accepted choices

Pietro approved preserving the selected seek point instead of jumping to the
following chunk boundary. Compact player layouts may reflow controls and bound
long visible metadata, retaining complete accessible strings and usable touch
areas. Piper/eSpeak may be built locally: Pietro confirmed no compatible
verified prebuilt is available. That answer does not authorize other downloads.

Akita's Appendix K describes 700-character, sentence-ending chunks and a below
800 recommendation for ElevenLabs dubbing. This does not establish Piper's
optimal input size. eSpeak's internal 800-byte source buffer is a different limit.

## Remaining acceptance and next work

Resume IOS-06, then remaining reader typography/font work, Settings cleanup and
research. Diagnose IOS-10 in the final native journey instead of changing
accessibility behavior speculatively. UIKit regressions are authored alongside
each native change; their execution and full app compilation remain pending.
Check seeded-reader clipping/raw-offset preservation and player playback across
background/overlays, generated chunk boundaries and chapter changes.

UI suggestions UI-P01–UI-P07 remain proposals, outside approved implementation.
Generic conversion-history detail still has a legacy HTTP-backed initializer;
it was observed during IOS-03 and remains a separate unverified follow-up.

## Preserved work outside this iOS change

The shutdown request explicitly included existing uncommitted work in the other
checkouts. These snapshots preserve it without combining it with this iOS PR
or claiming validation. Review and split each snapshot into coherent PRs before
integration; do not merge these backup branches wholesale.

| Backup branch | Snapshot commit | Saved files |
| --- | --- | --- |
| `wip/shutdown-main-workspace-20261027` | `7cb696d9d0fb446978a8b2ff65b57ea5bec31226` | 43 |
| `wip/shutdown-model-download-20261027` | `6318856d3a78ddceae2260419ec61c3d1374c5da` | 71 |
| `wip/shutdown-build-cache-20261027` | `3911c6ec2600aeceeeea7236dad72fdf88e5f334` | 15 |
| `wip/shutdown-iphone-delivery-20261027` | `863bd3878f` | Existing clean commit |
| `wip/shutdown-protected-pauses-20261027` | `5a48f783709dd623357289d13ed4ce2e060ce944` | 2 |

Pushes were read back and verified against each local commit. Ignored build
outputs, private logs, app data and installed models remain local. The protected
pauses snapshot includes its pre-existing 2.2 MiB Silero asset and MIT license;
this preservation does not enable it in the app or authorize new downloads.
