# Snapshot regression suite

Pixel-level snapshot tests for the SwiftUI surfaces — Reader, Library,
Mini/Full player. Catches layout regressions (margins, safe-area
clipping, theme palette drift) on every PR.

## What lives here

This `Snapshots/` directory is **populated by the test runner**, not by
hand. After the first bootstrap run, PNG references live in
subfolders named after the test class — e.g.:

```
Snapshots/
├── ReaderSnapshotTests/
│   ├── testReaderLightThemeAcrossFullMatrix.1.png
│   ├── testReaderDarkThemePortraitIPhones.1.png
│   └── …
├── PlayerSnapshotTests/
└── LibrarySnapshotTests/
```

## Running

```bash
# Single suite
xcodebuild test \
  -only-testing:EpubToMp3Tests/ReaderSnapshotTests \
  -scheme EpubToMp3 \
  -destination "platform=iOS Simulator,name=iPhone 16"

# Full snapshot tier
xcodebuild test \
  -only-testing:EpubToMp3Tests/ReaderSnapshotTests \
  -only-testing:EpubToMp3Tests/PlayerSnapshotTests \
  -only-testing:EpubToMp3Tests/LibrarySnapshotTests \
  -scheme EpubToMp3 \
  -destination "platform=iOS Simulator,name=iPhone 16"
```

## Bootstrap (first run, no references in repo yet)

When the tests run with no PNG on disk, swift-snapshot-testing writes
the new image AND fails the test (so an absent reference cannot pass
silently). The workflow:

1. Open `EpubToMp3Tests/SnapshotConfig.swift` and set
   `SnapshotConfig.record = true`.
2. Run the suite (commands above). All tests will "fail" but the PNGs
   are now on disk under the appropriate `Snapshots/` subfolder.
3. Inspect the PNGs — these become your baseline. Anything wrong here
   (clipped text, wrong theme) becomes locked-in. Fix the bug first if
   it's a layout regression, not the snapshot.
4. Flip `SnapshotConfig.record` back to `false`.
5. Run the suite again — it should now pass.
6. Commit the PNGs together with `SnapshotConfig.swift` (record=false).

## Updating references after an intentional UI change

Same flow as bootstrap — flip `record = true`, run, eyeball the diff
on disk, flip back to `false`. Reviewers should look at the PNG diff
in PR ("Files changed" → image viewer) before approving.

## Why precision = 0.99

The `assertSnapshot` calls use `precision: 0.99` (1% pixel diff
tolerance). This absorbs font-antialiasing drift across Xcode /
simulator runtime versions without masking real regressions — a true
layout shift moves *far* more than 1% of pixels.

## Device matrix

Defined in `EpubToMp3Tests/SnapshotConfig.swift`:

| Device          | Trait used by lib    | Why                                       |
|-----------------|----------------------|-------------------------------------------|
| iPhone SE       | `.iPhoneSe`          | Smallest target — worst-case width budget |
| iPhone 8        | `.iPhone8`           | Pre-notch baseline                        |
| iPhone 15 Pro   | `.iPhone13Pro`       | Dynamic Island; current-gen baseline      |
| iPhone 15 ProMax| `.iPhone13ProMax`    | Tallest iPhone — column-width caps engage |
| iPad mini       | `.iPadMini`          | Smallest iPad — sidebar transitions       |
| iPad Pro 12.9   | `.iPadPro12_9`       | Largest target — multi-column layouts     |

The library does not ship iPhone 15-series traits explicitly because
those devices share the trait/layout of iPhone 13-series — only the
camera bump changes.

## What we deliberately don't snapshot

- macOS surfaces — `swift-snapshot-testing` UIKit hosting doesn't
  apply. AppKit rendering needs a different code path that is not
  worth the maintenance cost for a companion app.
- Anything driven by real-time state (audio waveforms, live spinners,
  conversion progress %) — snapshots would be inherently flaky.
- Localised string variants — tested at the model layer.
