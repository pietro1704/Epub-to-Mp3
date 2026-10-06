# iPhone Local Audio Download and Persistence Research

Status: resolved research for [Audit durable download state for embedded audio](https://github.com/pietro1704/Epub-to-Mp3/issues/467).

## Primary sources

- `ios/EpubToMp3/EpubToMp3/Features/Conversion/Services/EmbeddedConversionCoordinator.swift:434-539,817-893`
- `ios/EpubToMp3/EpubToMp3/Features/Offline/Services/DownloadManager.swift:28-325,328-475,500-562`
- `ios/EpubToMp3/EpubToMp3/Features/Offline/Services/ChapterCacheManager.swift:6-218`
- `ios/EpubToMp3/EpubToMp3/Features/Offline/Services/AudiobookCacheEviction.swift:6-330`
- `ios/EpubToMp3/EpubToMp3/Features/Settings/Views/SettingsScreenController.swift:241-275,426-435`

## Current storage paths

- Embedded conversion writes complete chapter MP3s to `Application Support/EpubToMp3/EmbeddedConversion/<book>/output`. They are excluded from backup and use `completeUntilFirstUserAuthentication` protection.
- A completed embedded snapshot stores each chapter as a `file://` URL.
- `DownloadManager` copies URL-backed chapters to `Documents/Audiobooks/<job>/chapters` and writes a durable `manifest.json`. Its file-download path explicitly supports `file://`, so it can promote an already generated embedded MP3 without network I/O.
- `ChapterCacheManager` separately synthesizes Edge MP3s into `Caches/epub2mp3-tts/<book>`. It duplicates conversion, retention, and status responsibilities instead of sharing the embedded pipeline.

## Verified limitations

- `enqueueAll` and `enqueueSelected` use only `snapshot.playableChapters`. Pending embedded chapters have no `downloadUrl`, so a whole-book download cannot ask conversion to create missing audio.
- Both public enqueue calls cancel any existing download task for the same book. A TOC chapter action can therefore cancel a whole-book operation rather than being merged as a priority request.
- `AudiobookCacheEviction` runs after download completion and evicts manifest-backed audiobooks by a 24-hour TTL or a fixed 2 GB budget. That conflicts with the confirmed rule that explicit downloads remain until the user removes them.
- Storage usage does not include `EmbeddedConversion` output, which means the current Settings total cannot represent the audio the player actually uses.
- No iOS ZIP-export producer or sharing surface exists. The only ZIP implementation is an EPUB reader.

## Decision input

There is no single source of truth today. The durable `AudiobookManifest` is the closest existing contract but only describes copied downloads. The implementation should extend or replace it with a local artifact manifest that represents temporary generated chapters, protected explicit downloads, failures, and export inputs. `AudioPlayer` should resolve the manifest's preferred local URL; it should not infer download truth from a backend URL. `ChapterCacheManager` should be retired or adapted behind that one store rather than continuing a second Edge conversion path.
