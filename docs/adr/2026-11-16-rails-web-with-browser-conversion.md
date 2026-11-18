# ADR: Rails web client with browser conversion (Rust/WASM + Piper)

Status: Accepted (owner, 2026-11-17)
Date: 2026-11-16

This document is the first step of PR-G. It contains an inventory of the React
client in `web/` (Part 1), a parity matrix with stable row IDs (Part 2) and the
architecture decision (Part 3).

Owner acceptance (2026-11-17): the ADR is accepted with the proposed default,
the first option, for every question Q-01 to Q-17 in section 3.15. Rows N-01 to
N-25 are therefore confirmed as not carried over (Q-17), and N-26 follows the
default of Q-10: stored jobs without synthesis receipts keep being accepted.

Binding owner decisions referenced below: D7 (Rails rewrite, React deleted only
at full parity, `ruby_app/rails_gateway` is the base, the Hugging Face Space is
kept), D14 (`converter-server` becomes model-independent in another PR), D16
(Capacitor, Tauri shim, AUR and desktop sidecar are removed elsewhere), D19 (no
voice models in the repository; explicit opt-in download), D33 (Hotwire for
navigation and forms; Rust/WASM for conversion, audio and the reader), D34
(generated WASM is not committed for the new web).

Evidence rules used here: every statement about the current system names a
file that was read in the worktree at `origin/master` (039561d6c7). Nothing was
built, installed or executed. Statements marked **(inferred)** follow from the
code but were not observed at runtime; statements marked **(unverified)** could
not be checked without running or installing something.

---

## Part 1 — Inventory of the React client (`web/`)

### 1.1 Runtime shape today

- `web/src/services/ConversionService.ts:conversionClient` is
  `new BrowserConversionClient()`. No environment variable or runtime switch
  selects another client. `BrowserConversionClient.mode` is the constant
  `'embedded'` (`web/src/services/BrowserConversionClient.ts:34`).
- Conversion runs in the browser: Rust `ConversionSession` (generated bindings
  in `web/src/wasm/`, source `crates/converter-wasm/src/session.rs`) decides
  segment order, provider policy and accepted audio; a module worker
  (`web/src/services/BrowserPiperWorker.ts`) runs the phonemizer
  (`@diffusionstudio/piper-wasm`) and ONNX Runtime Web
  (`onnxruntime-web/wasm`, `numThreads = 1`) and encodes MP3 through the Rust
  export `encode_pcm_f32_mp3`.
- Durable state lives only in the browser: IndexedDB database
  `ebook-tts.jobs.v1`, object store `jobs` (`BrowserJobStore.ts`); OPFS
  directory `piper/` for model files (`BrowserModelInstallation.ts`,
  `BrowserPiperRuntime.ts`); `localStorage` for preferences (keys listed in
  3.4).
- The deployed image (`Dockerfile`) builds `web/dist` with Node and serves it
  from `converter-server` (`crates/converter-server/src/main.rs`,
  `fallback_service(ServeDir::new("web/dist"))`) on port 7860. The embedded web
  client does not call any `/api` route on a reachable path (see 1.3).
- Locales: `pt` and `en` only (`web/src/i18n/translation_contract.ts:Locale`).
  A brace-aware count over the locale sources gives 639 leaf entries per locale
  (identical in both); 579 properties are declared in the three
  `translation_*_types.ts` files, the rest are entries of `Record<…>` maps.
  The count was produced by a script, not by the TypeScript compiler.
- There is **no service worker** in `web/` (no match for `serviceWorker`,
  `workbox` or `sw.js` in `web/src`, `web/public`, `web/index.html`,
  `web/vite.config.ts`, `web/scripts`). The PWA surface is the manifest and
  icons only.
- No cross-origin isolation is configured anywhere: no
  `Cross-Origin-Opener-Policy`, `Cross-Origin-Embedder-Policy`,
  `SharedArrayBuffer` or `crossOriginIsolated` reference exists in `web/src`,
  `web/scripts`, `web/vite.config.ts`, `web/index.html`, `Dockerfile`,
  `ruby_app/` or `crates/converter-server/src`. `BrowserPiperRuntime.prepare`
  sets `env.wasm.numThreads = 1`.

### 1.2 Live user-visible capabilities

Each entry is carried into the parity matrix under the ID shown.

**Shell**

| ID | Capability | Source |
| --- | --- | --- |
| P-01 | App shell, footer with version | `web/src/components/Layout.tsx:Layout`; `web/vite.config.ts` (`__APP_VERSION__`) |
| P-02 | Theme switch auto/light/dark, persisted, follows OS in auto | `components/TopBar.tsx:TopBar`; `theme/ThemeProvider.tsx:ThemeProvider` (key `ebook-tts-theme`); `styles/theme_tokens.css` |
| P-03 | Locale switch auto/pt/en, persisted, sets `<html lang>` | `components/TopBar.tsx`; `i18n/I18nProvider.tsx:I18nProvider` (key `ebook-tts-locale`); `i18n/translations.ts:resolveLocale` |
| P-04 | Three tabs (setup, progress, downloads): gating, "active" badge, automatic tab changes by phase, panels hidden rather than unmounted | `AppView.tsx` (`role="tablist"`, `hidden` panels); `useWorkspaceIntents.ts:handleTabChange`, `canViewProgress`, `canViewDownloads`; `useCompletedConversionEffects.ts` (first effect); `useWorkspaceTabs.tsx` |
| P-05 | Hero: title, author, phase, engine/voice/language, progress bar, ETA, queue position, collapsed summary | `components/Hero.tsx:Hero` |
| P-06 | Help drawer with local-runtime text, status, job id, progress; overlay and Escape close it | `AppView.tsx` (`help-drawer`, `!hasBackendDiagnostics` branch); `useBackendRestartDialog.ts` (Escape effect only) |
| P-07 | Notifications on error/cancel through the browser Notification API; in-page toasts when the host is `*.hf.space` | `useApplicationNotifications.ts:notifyUser`, `pushHfNotification`; `usePlaybackWorkspace.ts` (host detection); `useCompletedConversionEffects.ts` |

**Setup tab**

| ID | Capability | Source |
| --- | --- | --- |
| P-08 | Choose books: multi-file input, drop on the form, add folder, 100 MB limit, extension filter | `components/FormBookSource.tsx`; `components/ConversionFormView.tsx` (drag handlers, folder input); `components/useFormUploadSession.ts:addFilesToQueue`; `config.ts:MAX_UPLOAD_BYTES` |
| P-09 | In-browser inspection of each selected EPUB (called "upload" in the UI): title/author, status uploading/ready/error | `services/BrowserConversionClient.ts:upload`; `services/EmbeddedConverter.ts:inspect`; `crates/converter-wasm/src/lib.rs:inspect_epub` |
| P-10 | Pending-book queue: drag reorder, up/down, remove, count, empty hints | `components/useFormBookQueue.ts`; `components/FormBookSource.tsx` |
| P-11 | "Use sample" loads `sample.epub` | `components/useFormSubmission.ts:handleUseSample`; `web/public/sample.epub` |
| P-12 | Narration policy: primary model from the Rust catalog, secondary (none / system / another model), saved defaults, per-job override with optional reserve voice | `components/FormNarrationPolicy.tsx`; `services/TtsCatalog.ts:loadTtsCatalog`, `browserSelections`; `services/TtsPreferences.ts` (key `ebook-tts.preferences.v1`, `effectiveTtsPreferences`); `components/useFormState.ts` |
| P-13 | Explicit model installation button with status idle/installing/installed/error and installed detection | `components/useFormState.ts:installModel`; `services/BrowserModelInstallation.ts:installBrowserModel`, `installedBrowserVoices`, `installFaberArtifacts`; `services/BrowserModelIntegrity.ts:verifyBrowserModel` |
| P-14 | Chapter range (`N` or `N-M`) | `components/FormChapterSelection.tsx` (`chapters` field); `BrowserConversionClient.ts:submit` (range parsing, lines 105-116) |
| P-15 | Job language (auto / pt / en) | `components/FormEngineOptions.tsx` (`language` select); `BrowserConversionClient.ts:submit` (line 121) |
| P-16 | Submit: missing-file error, busy label, waits for pending inspections, starts the batch | `components/useFormSubmission.ts:handleSubmit`; `components/ConversionFormView.tsx` |
| P-17 | Batch: sequential processing, queue display with reorder / resume / clear, add more books during a conversion, skip current | `hooks/useConversionQueue.ts`; `components/QueueDisplay.tsx`; `useQueueDisplay.tsx`; `components/QuickQueueAdder.tsx`; `hooks/useConversionControls.ts:skipCurrent`, `resumeQueue`, `clearQueue`, `reorderQueue` |
| P-18 | Active-conversion banner on the setup tab (status, ETA, view progress, cancel, skip) | `components/ActiveConversionBanner.tsx` |
| P-19 | Saved-batch banner after reload (resume / dismiss / "needs re-upload" count) | `AppView.tsx` (`savedBatch` block); `services/ConversionCache.ts:savePendingBatch`; `hooks/useConversionIntents.ts` (`resumeBatch`, `dismissSavedBatch`) |
| P-20 | Resumable jobs panel (interrupted, failed, cancelled): resume, remove, hidden ids | `components/ResumableJobsPanel.tsx`; `BrowserConversionClient.ts:getResumableJobs`, `resume`, `removeJob`; `hooks/useConversionHistory.ts`; `hooks/useConversionResume.ts`; key `ebook-tts-hidden-resumable` |
| P-21 | Recent jobs panel (finished with outputs): view outputs, remove, collapse | `components/RecentJobsPanel.tsx`; `BrowserConversionClient.ts:getRecentJobs`; key `ebook-tts-hidden-recent` |

**Conversion engine (no direct UI, observable through the tabs)**

| ID | Capability | Source |
| --- | --- | --- |
| P-22 | Job creation and serial execution: Rust segment loop, Piper synthesis in a worker with a 120 s deadline, MP3 encoding in Rust, per-chapter MP3 | `services/BrowserJobExecution.ts:execute`; `services/BrowserConversionRuntime.ts:platformRuntime`, `createBrowserSynthesis`; `services/BrowserPiper.ts`; `services/BrowserPiperWorker.ts`; `services/BrowserPiperRuntime.ts` |
| P-23 | Persistence and restore: jobs and audio blobs in IndexedDB, receipts and sealed cache identity checked on restore, running jobs become `interrupted` after reload | `services/BrowserJobStore.ts:IndexedDBBrowserJobStore`; `services/BrowserJobRepository.ts:restore`, `persist`; `services/BrowserAudioIdentity.ts` |
| P-24 | Cancel (with confirmation; the job is removed) and resume (keeps completed chapters and saved policy state) | `useWorkspaceIntents.ts:handleCancelClick`; `hooks/useConversionControls.ts:cancel`; `BrowserJobExecution.ts:cancel`, `resume` |
| P-25 | Provider failure: secondary model through `provider_failed`; failure category `tts_provider`; unavailable selections rejected explicitly, never switched to HTTP or Edge | `BrowserJobExecution.ts` (synthesis `catch`); `BrowserConversionClient.ts:submit` (lines 88-96); `docs/wasm-capability-boundary.md` |
| P-26 | Storage failure messages (quota exceeded, blocked by another tab, IndexedDB unavailable) | `services/BrowserJobStore.ts:storageError`, `onblocked` |

**Progress tab (the reader lives here)**

| ID | Capability | Source |
| --- | --- | --- |
| P-27 | Status: phase chip, job id, ETA (client estimate plus one-second countdown), cancel/skip, chapters x/y, progress percent and bar, error text with category hint | `components/StatusPanelView.tsx`; `components/useConversionStatus.ts`; `hooks/conversion_eta.ts:estimateEtaSeconds`; `hooks/useHttpRuntimeHealth.ts` (third effect) |
| P-28 | Event log toggle (flow messages with timestamps) | `StatusPanelView.tsx` (`showRawLog`); `useConversionStatus.ts:rawLogText` |
| P-29 | Chapter list: status, expand, per-chapter audio, segment list with text and audio, search across texts with previous/next match, download full text as `.txt`, scroll to current | `components/ChapterProgressListView.tsx`; `components/useChapterProgress.tsx`; `components/useChapterManifestStore.ts` |
| P-30 | Reader open/close inline and as a modal | `StatusPanelView.tsx` (`status-panel__reader-actions`, `reader-modal`) |
| P-31 | Reader: chapter list with status badges, paginated text, previous/next page, ←/→ keys, loading / error with retry / empty states | `components/EbookReaderPanelView.tsx`; `components/useReaderPosition.ts`; `components/reader_pagination.ts`; `components/reader_markup.ts`; `utils/readerSanitizer.ts` |
| P-32 | Reader preferences: theme paper/mist/ink, serif/sans, font size, line height, width, follow audio; persisted | `components/reader_preferences.ts` (key `epub-to-mp3:reader-prefs`); `EbookReaderPanelView.tsx` toolbar |
| P-33 | Reader search with match count and highlight; highlight of the segment being played; automatic follow with manual pause | `components/reader_highlighting.ts`; `useReaderPosition.ts` |
| P-34 | Sequential player while converting: start, previous/next chapter, jump, speed (persisted), stop, per-job position (persisted), current segment text, segment chips, Media Session metadata | `components/StreamingAudioPlayerView.tsx`; `components/useChapterStreamSession.ts`; `components/playback_preferences.ts` (keys `epub-to-mp3:player-speed`, `epub-to-mp3:player-pos:<jobId>`) |
| P-35 | Listening steers conversion: reposition to the chapter being heard and feed playback progress back to Rust | `useChapterStreamSession.ts` (`listenFrom`, `playbackFeedback` calls); `BrowserJobExecution.ts:listenFrom`, `playbackFeedback` |
| P-36 | Browser-speech fallback, listening only: notice, listen / pause / resume / stop, retry Piper, active voice shown, failure states; prefers Luciana for pt-BR; never produces MP3 or advances the job | `components/NativeReaderFallback.tsx`; `services/BrowserNativeSpeech.ts`; `services/NativePlaybackPresentation.ts`; `BrowserConversionClient.ts:getNativePlaybackPolicy` |

**Downloads tab**

| ID | Capability | Source |
| --- | --- | --- |
| P-37 | Per-chapter MP3: inline player (one playing at a time) and download link | `components/DownloadsPanel.tsx` (`downloads-chapters`, `handlePlay`) |
| P-38 | Ready-downloads list: select a job, remove, bulk download | `components/ReadyDownloadsList.tsx`; `usePlaybackWorkspace.ts:readyDownloadJobs` |
| P-39 | "Viewing previous job" banner, new-conversion button, empty placeholders | `DownloadsPanel.tsx` (`context`, `downloads-panel__cta`, placeholders); `usePlaybackWorkspace.ts:downloadsContext`; `useWorkspaceIntents.ts:handleReset` |
| P-40 | Share block: native share, WhatsApp, copy link. In the browser the shared URL is a `blob:` object URL (`shareUrl = zipFile?.url ?? downloads[0]?.url`), which only resolves in the tab that created it **(inferred)** | `DownloadsPanel.tsx:handleNativeShare`, `handleWhatsappShare`, `handleCopyLink` |

**Cross-cutting**

| ID | Capability | Source |
| --- | --- | --- |
| P-41 | Two locales with identical key sets | `web/src/i18n/pt_*.ts`, `en_*.ts`, `translation_*_types.ts` |
| P-42 | PWA manifest, icons, favicon, theme colour (no service worker) | `web/public/site.webmanifest`; `web/public/app-icon-*.png`, `apple-touch-icon.png`, `favicon.*`; `web/index.html` |
| P-43 | Accessibility affordances: tablist semantics, `role="alert"` errors, `role="status"`, `aria-live` regions, progressbar roles, `aria-expanded` toggles, labelled inputs, `:focus-visible` styles, keyboard (Escape, arrows) | `AppView.tsx`; `Hero.tsx`; `ChapterProgressListView.tsx`; `FormBookSource.tsx`; `NativeReaderFallback.tsx`; `web/src/styles/*.css` (`:focus-visible` rules) |
| P-44 | Latency evidence: in-memory, bounded recording of reader-open, progressive-playback and seek journeys; stable JSON serialisation | `services/LatencyObservation.ts:LatencyObservationStore`, `serializeLatencyEvidence`; recorded from `useReaderPosition.ts` and `useChapterStreamSession.ts` |
| P-45 | Loading states: initial skeleton, lazy panel fallbacks, resumable-jobs loading, reader loading | `web/index.html` (`app-loading`); `ApplicationPresentation.tsx:ComponentFallback`; `ResumableJobsPanel.tsx` (`loading`); `EbookReaderPanelView.tsx` |

### 1.3 Verification of the planning-time "dead" candidates

"Dead" means no reachable caller in the deployed browser build. "Inert" means
the control is rendered and reachable, but its value is ignored or only
produces an error.

| Candidate | Finding | Evidence |
| --- | --- | --- |
| Every `mode === 'http'` branch | **Dead.** Eight sites compare the mode: `useApplicationState.ts:54` (`hasBackendDiagnostics`), `FormVoiceOptions.tsx:73`, `useFormNarrationPolicy.ts:59` and `:112`, `FormEngineOptions.tsx:50-53`, `useConversionState.ts:53`, `useHttpRuntimeHealth.ts:46`, `useConversionSnapshots.ts:110`. All evaluate to the embedded side because `conversionClient` is always `BrowserConversionClient`. | `services/ConversionService.ts:9`; `BrowserConversionClient.ts:34` |
| `HttpConversionClient.ts` | **Dead.** Instantiated only in tests (`test/App.integration.test.tsx:72`, `test/ConversionService.test.ts`, `services/ConversionService.test.ts`). | `grep "new HttpConversionClient"` over `web/src` |
| `http_event_stream.ts` | **Dead.** Imported only by `HttpConversionClient.ts`. | importer search |
| `http_conversion_form.ts` | **Dead.** Imported by `HttpConversionClient.ts`; re-exported as `__buildFormData` for tests. | `ConversionService.ts:7` |
| `http_conversion_response.ts` | **Dead.** Imported by the HTTP client, the event stream and the mock client; `normalizeErrorMessage` / `normalizeAssetUrl` are re-exported and have no non-test consumer. | importer search |
| `TelemetryService.ts` | **Dead.** Imported only by `TelemetryPanel.tsx`. | importer search |
| `useHttpRuntimeHealth.ts` | **Partly alive.** Effect 1 (health polling) returns immediately in embedded mode. Effect 2 (fallback poll) is reachable but does nothing while snapshots are fresh; `BrowserConversionClient.poll` delivers one every 100 ms **(inferred)**. Effect 3 (one-second ETA countdown) is alive and is carried in P-27. | `useHttpRuntimeHealth.ts:45-139`, `:141-230`, `:232-256` |
| `conversion_runtime_health.ts` | **Partly alive.** `fetchInitialJobSnapshot`, `fetchResumedJobSnapshot`, `isNetworkError`, `sleepMs`, `RESTART_GRACE_MS` are used by live hooks. `pingBackendHealth` and `resolveHealthEndpoint` are dead: their only callers are behind the embedded early returns. | `useConversionRunSession.ts`; `useConversionSnapshots.ts:110-114` |
| `useSystemStats.ts` | **Dead in effect.** Called twice, both with interval 0 in embedded mode, which disables fetching. | `useConversionState.ts:53`; `useApplicationState.ts:56,76`; `useSystemStats.ts` (`pollIntervalMs <= 0`) |
| `SystemStatsPanel.tsx`, `TelemetryPanel.tsx` | **Dead.** Rendered only under `hasBackendDiagnostics`. | `AppView.tsx` (help drawer) |
| `ConversionHistoryPanel.tsx` | **Dead.** Rendered only under `hasBackendDiagnostics`; calls `/api/sessions`, which `converter-server` does not route. | `AppView.tsx`; `crates/converter-server/src/main.rs` router |
| `VoicePreviewButton.tsx` | **Dead.** Rendered only when `mode !== 'embedded'`; calls `/api/voice-preview`, not routed by `converter-server`. | `FormVoiceOptions.tsx:73` |
| `useBackendRestartDialog.ts` | **Partly alive.** The restart handlers are reachable only from the dead diagnostics button, and `BrowserConversionClient` has no `restartBackend`. The Escape-closes-help effect in the same hook is alive (P-06). `ConfirmDialog.tsx` is used only by this restart flow. | `useBackendRestartDialog.ts`; `AppView.tsx`; `conversion_client_contract.ts` |
| `services/mock_conversion_client.ts` | **Dead.** Re-exported from `ConversionService.ts:5`; no importer, including tests. | importer search for `MockConversionClient` |
| `BookCoverCard.tsx` | **Dead.** Imported only by `test/BookCoverCard.test.tsx`. | importer search |
| `UiHealthPanel.tsx` | **Dead.** Imported only by its test. The recorder behind it (`uiIssueMonitor.ts:reportUiIssue`) is alive: it is called from `useNativeStartup.ts` (window error handlers) and `useReaderPosition.ts`, writes `localStorage` key `epub-to-mp3:ui-issues` and the console, and nothing displays it. | importer search |
| `public/index.html` | **Dead.** A second HTML entry that references `/src/main.tsx`; nothing links to it. Which file wins in `dist/` was not checked **(unverified)**. | `web/public/index.html`; `web/index.html` |
| `public/log-viewer.html` | **Dead in the browser.** Calls `window.__TAURI__…invoke("get_server_logs")`; referenced only from `CHANGELOG.md`. | `web/public/log-viewer.html:168-175` |
| `@mintplex-labs/piper-tts-web` | **Dead dependency.** Present in `web/package.json`; no import in `web/src`, `web/scripts`, `web/plugins` or `web/vite.config.ts`. | `grep` over `web/` excluding the lockfile |
| Tauri (`lib/tauri.ts`, `UpdateBanner.tsx`, `useNativeStartup.ts`) | **Dead in the browser.** Every use is guarded by `isTauri()` (`window.__TAURI__`): startup log panel, engine error banner, update banner, `tauri-open-books`, path upload to `/api/uploads/local`, download interception, OS notification, native theme/locale menu events. No `tauri.conf.json` exists within three directory levels of the repository root. The window error handlers in `useNativeStartup.ts` are not Tauri-specific (see `UiHealthPanel` above). | `AppView.tsx:107-143`; `Layout.tsx`; `useFormUploadSession.ts:61-73,200-298`; `DownloadsPanel.tsx:142`; `useCompletedConversionEffects.ts:136` |
| Capacitor | **Dead.** `capacitor.config.ts`, `@capacitor/*` dependencies, `build:mobile` and `cap:*` scripts, `.env.mobile`. No import in `web/src`; no `web/ios` or `web/android` directory. The only consumer is a dependency-security test (`scripts/minimatch.node-tests.mjs`). | `web/package.json`; importer search |
| `/api` proxy in `vite.config.ts` | **Dead for the embedded client.** Every `/api` caller is one of the dead items above or Tauri-only. `VITE_API_BASE` in `.env.desktop`, `.env.mobile`, `.env.production` has no live consumer for the same reason. | `grep resolveApiUrl` over `web/src` |
| Options rejected by `BrowserConversionClient.submit` (lines 66-84) | **Inert.** `sections`, `fromChapterToEnd`, `fromChapterToChapter`, `priority`, `footnoteMode` other than `inline`, `enableCharacterVoices`, `formattingCues`, `multiEngineParallel`, `exportToIphone`, `bitrate`, `sampleRate`, `channels`: the controls render inside "Advanced", and setting any of them makes submit throw "This browser does not support the selected advanced conversion options." | `BrowserConversionClient.ts:66-84`; `FormChapterSelection.tsx`; `FormVoiceOptions.tsx`; `FormPerformanceOptions.tsx`; `FormAudioOptions.tsx` |

Additional findings not on the candidate list:

- **Advanced options silently ignored.** `submit` reads only
  `tts_preferences`, `uploadId`/`file`, `chapters` and `language`. These
  rendered controls have no effect: `voice`, `model`, `noParallel`,
  `maxPerformance`, `parallelSlots`, `chapterStallSeconds`, `edgeNetworkTier`,
  `edgeChunkChars`, `edgeMaxSegmentSeconds`, `edgeEnableParallel`,
  `edgeAutoTune`, `edgeStableMode`, `engineChainFallback`, `piperMaxProcs`,
  `verbose`, `clearCache`, `forceReprocess`, `filterChapters`,
  `useLanguageDetection`, `prioritizePrimaryLanguage` and the eight
  `healthCheck*` fields (`FormPerformanceOptions.tsx`, `FormEdgeOptions.tsx`,
  `FormAudioOptions.tsx`, `FormOutputOptions.tsx`, `FormHealthOptions.tsx`).
- **Engine select and engine cards are single-choice.** Every engine other
  than Piper is disabled in embedded mode (`FormEngineOptions.tsx:50`), so the
  "auto" comparison table is unreachable and the select cannot change the job.
- **Edge and system-as-primary are rejected** (`BrowserConversionClient.ts`
  lines 88-96); Edge entries are rendered disabled in `FormNarrationPolicy.tsx`.
  The "allow online fallback" checkbox is stored but cannot enable anything in
  the browser **(inferred)**.
- **ZIP and log outputs never exist.** The browser produces only
  `chapter-N.mp3` (`BrowserJobExecution.ts`), so the ZIP button, log preview
  and log download in `DownloadsPanel.tsx` never render.
- **CLI reproduction never renders.** `utils/cliReproduction.ts` requires
  `values.localPath`, which only the Tauri path upload sets.
- **Snapshot fields the browser client never sets**, so their UI never shows:
  cover image (`upload` returns no `coverUrl`), detected language, current
  chapter, status hint, engine status, chars-per-second speed, parallelism
  meter, server raw log, chapter retry details (compare `JobSnapshot` in
  `types/conversion.ts` with the snapshot built in `BrowserConversionClient.ts`
  and updated in `BrowserJobExecution.ts`).
- **Reader shows plain paragraphs.** `inspect_epub` returns `text` but no
  `html` or `css` per chapter (`crates/converter-wasm/src/lib.rs`), so
  `buildReaderPages` always takes the text fallback and EPUB styling is never
  rendered in the browser **(inferred)**.
- **PDF is offered but cannot be opened.** The picker accepts
  `application/pdf` and `.pdf` (`FormBookSource.tsx`,
  `conversion_form_choices.ts:SUPPORTED_BOOK_EXTENSIONS`), but the only
  inspection export is `inspect_epub`; a PDF ends as a per-file error
  **(inferred)**.
- **Saved-batch resume cannot find its books after a reload.** Uploads are an
  in-memory `Map` in `BrowserConversionClient`, and `File` objects are replaced
  by `null` when the batch is saved (`ConversionCache.ts:savePendingBatch`), so
  a resumed entry fails with "Select an EPUB in this browser session."
  **(inferred)**.
- **`downloadLatencyEvidence` has no caller** in `web/src` or `web/scripts`.
- **`EmbeddedConverter.previewChapter`, `convertToAudio` and
  `embeddedCapabilities`** are referenced only by their own test; the runtime
  uses `embeddedConverter.inspect` only.
- **WASM exports `encode_wav_mp3` and `health`** have no caller in `web/src`
  or `web/scripts` outside the generated bindings (consistent with D14).

---

## Part 2 — Parity matrix

### 2.1 Carried over

Paths in "New location" are relative to `ruby_app/rails_gateway/`. `ctl:` is a
Stimulus controller in `app/javascript/controllers/`; `rt:` is a first-party
ES module in `app/javascript/runtime/`; `worker:` is a file of the generated
runtime tree (3.3); `rust:` is a `converter-wasm` export. React locations are
those of the same ID in 1.2. Every acceptance statement is to be automated in
the slice named in 3.10.

| ID | Capability | New location | Acceptance check |
| --- | --- | --- | --- |
| P-01 | Shell and version footer | `layouts/application.html.erb`; `workspace/show.html.erb` | `GET /` returns 200 HTML containing the main landmark and the footer shows the application version. |
| P-02 | Theme auto/light/dark | `shared/_top_bar.html.erb`; `PreferencesController#update`; `ctl:theme` | Choosing dark sets the theme on `<html>` without a flash on the next request; auto follows an emulated OS scheme change; a value stored under `ebook-tts-theme` is honoured on first visit. |
| P-03 | Locale auto/pt/en | `shared/_top_bar.html.erb`; `PreferencesController#update`; `config/locales/` | Choosing English re-renders every visible string in English and sets `lang="en-US"`; auto uses `Accept-Language`; a value stored under `ebook-tts-locale` is honoured on first visit. |
| P-04 | Three tabs, gating, automatic tab changes | `workspace/_tabs.html.erb`; `ctl:tabs`; `rt:workspace_store` | Progress and downloads tabs are disabled before any job; submitting moves to progress; success moves to downloads; cancel returns to setup; audio keeps playing while tabs change. |
| P-05 | Hero | `workspace/_hero.html.erb`; `ctl:hero` | During a conversion the hero shows title, author, phase, progress bar with `aria-valuenow`, ETA and "n of m" for batches. |
| P-06 | Help drawer | `workspace/_help_drawer.html.erb`; `ctl:help-drawer` | The toggle exposes `aria-expanded`; Escape and the overlay close it; it shows capability text, status and job id. |
| P-07 | Notifications | `ctl:notifications` | With permission granted an error produces a Notification; on a `*.hf.space` host without permission an in-page `role="status"` toast appears and dismisses itself. |
| P-08 | Choose books | `setup/_book_source.html.erb`; `ctl:book-picker` | Input, drop and folder selection add `.epub` files; a file over 100 MB shows the size error and is not queued. |
| P-09 | In-browser inspection | `rt:conversion_client`; `rust:inspect_epub` | After choosing `sample.epub` its row shows title, author and "ready"; no request carrying book bytes leaves the browser. |
| P-10 | Pending-book queue | `setup/_book_queue.html.erb`; `ctl:book-queue` | Reordering by buttons and by drag changes submission order; remove deletes the row; the count updates. |
| P-11 | Sample book | `public/sample.epub`; `ctl:book-picker` | "Use sample" queues `sample.epub` served from the same path as today (`/sample.epub`). |
| P-12 | Narration policy | `setup/_narration_policy.html.erb`; `ctl:narration-policy`; `rt:tts_catalog`; `rt:tts_preferences` | Choices come from `tts_catalog_json_v2`; the default is Faber medium primary with system secondary; changes persist under `ebook-tts.preferences.v1`; a per-job override does not change the saved default. |
| P-13 | Model installation | `setup/_narration_policy.html.erb`; `ctl:model-install`; `rt:model_installation`; `rt:model_integrity` | No model request happens before the button is pressed; after pressing, both files are in OPFS `piper/` with matching SHA-256 and the status reads "installed"; a corrupted download leaves the previous files untouched. |
| P-14 | Chapter range | `setup/_form.html.erb`; `rt:conversion_client` | `1-2` converts exactly two chapters; `0`, `3-1` and text show the range error. |
| P-15 | Job language | `setup/_form.html.erb` | The chosen language reaches `ConversionSession`; "auto" uses the EPUB language, then `pt-BR`. |
| P-16 | Submit | `setup/_form.html.erb`; `ctl:conversion-form` | Submitting without a ready book shows a `role="alert"` message; with one, the button shows the busy label and a job appears. |
| P-17 | Batch queue | `workspace/_queue.html.erb`; `ctl:batch-queue`; `rt:workspace_store` | Two queued books convert in order; skip moves to the second; a book added during the first runs after it; clear empties the queue. |
| P-18 | Active-conversion banner | `setup/_active_conversion.html.erb`; `ctl:status` | While converting, the setup tab shows status, ETA and working cancel / view-progress buttons. |
| P-19 | Saved-batch banner | `setup/_saved_batch.html.erb`; `ctl:batch-queue` | After a reload during a batch, the banner lists the remaining count; dismiss removes it. The resume behaviour depends on Q-07. |
| P-20 | Resumable jobs | `setup/_resumable_jobs.html.erb`; `ctl:job-library` | After a reload mid-conversion the job is listed as interrupted; resume continues without re-synthesising completed chapters; remove deletes it from IndexedDB. |
| P-21 | Recent jobs | `setup/_recent_jobs.html.erb`; `ctl:job-library` | A finished job is listed after a reload; "view outputs" opens the downloads tab with its chapters; remove hides it. |
| P-22 | Conversion execution | `rt:job_execution`; `rt:piper_client`; `worker:piper_worker`; `rust:ConversionSession`, `encode_pcm_f32_mp3` | With the model installed, converting `sample.epub` yields one decodable MP3 per chapter; with a fixture worker the same flow passes without a model. |
| P-23 | Persistence and restore | `rt:job_store`; `rt:job_repository`; `rt:audio_identity` | A job written by the React build (database `ebook-tts.jobs.v1`, version 1) opens in the Rails build with its audio, and the reverse also holds; a tampered blob marks the job interrupted. |
| P-24 | Cancel and resume | `ctl:status`; `rt:job_execution` | Cancel asks for confirmation, stops synthesis within one segment and removes the job; resume restores policy state. |
| P-25 | Provider failure | `rt:job_execution`; `rt:conversion_client` | A failing primary with a model secondary continues and logs the secondary voice; with a system secondary the job fails with category `tts_provider`; an Edge or system-primary selection is rejected with the explicit message; no network request to a TTS service is made. |
| P-26 | Storage failures | `rt:job_store` | Simulated quota, blocked and missing IndexedDB each show their distinct message and do not report success. |
| P-27 | Status panel | `progress/_status.html.erb`; `ctl:status` | Phase chip, chapters x/y, percent and bar track the job; ETA decreases every second; a failed job shows the error and category hint. |
| P-28 | Event log | `progress/_status.html.erb`; `ctl:status` | The toggle shows timestamped flow messages in an `aria-live` region and hides them again. |
| P-29 | Chapter list | `progress/_chapters.html.erb`; `ctl:chapter-progress` | A completed chapter expands to its audio and segments; search reports the hit count and steps through matches; "download text" saves a `.txt`. |
| P-30 | Reader inline and modal | `progress/_reader.html.erb`; `ctl:reader` | The reader opens inline and as a `role="dialog"` modal; closing the modal returns to inline. |
| P-31 | Reader content | `ctl:reader`; reader document from Rust (Q-03) | The chapter list selects chapters; page buttons and ←/→ flip pages; markup from the book cannot execute script or load remote resources; loading, error-with-retry and empty states render. |
| P-32 | Reader preferences | `ctl:reader-preferences` | Each control changes the rendered text immediately and survives a reload under `epub-to-mp3:reader-prefs`. |
| P-33 | Reader search and audio follow | `ctl:reader` | Search shows the match count and highlights matches; during playback the current segment is highlighted and the page follows; choosing another chapter pauses following until audio changes chapter. |
| P-34 | Sequential player | `progress/_player.html.erb`; `ctl:player` | Playback starts while conversion continues; previous/next/jump change chapter; speed and position persist under their existing keys; Media Session shows title and author. |
| P-35 | Listening steers conversion | `ctl:player`; `rt:job_execution`; `rust:set_listening_position_json_v2`, `playback_feedback_json_v2` | Jumping to an unconverted chapter makes that chapter the next one synthesised. |
| P-36 | Browser-speech fallback | `progress/_native_fallback.html.erb`; `ctl:native-fallback`; `rt:native_speech` | After a `tts_provider` failure with system secondary, the controls appear, speak with an installed local voice (Luciana first for pt-BR), show the voice name, and no MP3 or download is created; without a voice the unavailable message shows; "retry Piper" resumes the job. |
| P-37 | Chapter downloads | `downloads/_panel.html.erb`; `ctl:downloads` | Each chapter has a player and a link that saves `chapter-N.mp3`; starting one player pauses the others. |
| P-38 | Ready-downloads list | `downloads/_ready_list.html.erb`; `ctl:ready-downloads` | Two finished jobs are listed; selecting one swaps the chapter list; bulk download saves every chapter. |
| P-39 | Downloads context and reset | `downloads/_panel.html.erb`; `ctl:downloads` | Viewing an older job shows the banner with "back to current"; "new conversion" returns to an empty setup form. |
| P-40 | Share block | `downloads/_share.html.erb`; `ctl:downloads` | Behaviour depends on Q-08; if carried unchanged, the three buttons behave as today and show the same feedback strings. |
| P-41 | Locale parity | `config/locales/pt-BR.yml`, `en.yml`; `test/i18n_parity_test.rb` | Both locale files have identical key sets; while `web/` exists a test proves every React key has a Rails counterpart or an N-row waiver. |
| P-42 | Manifest and icons | `public/site.webmanifest`; `public/*.png`, `favicon.*`; layout `<link>` tags | The manifest is served at `/site.webmanifest` with the same fields; icons resolve; no service worker is registered. |
| P-43 | Accessibility affordances | all views and controllers | System tests assert roles and names for tabs, alerts, status regions, progress bars and toggles; every interactive element is reachable by keyboard with a visible focus style. |
| P-44 | Latency evidence | `rt:latency_observation` | Opening the reader and starting playback record the same journey kinds and transitions as today; the serialised JSON has `schemaVersion: 1`. |
| P-45 | Loading states | layout skeleton; controllers | Before the runtime is ready the page shows a loading state in the server-selected locale; lists show a loading state while IndexedDB is read. |

### 2.2 Not carried over (owner confirms row by row)

| ID | Item | Class | Evidence |
| --- | --- | --- | --- |
| N-01 | HTTP client: `HttpConversionClient.ts`, `http_event_stream.ts`, `http_conversion_form.ts`, `http_conversion_response.ts` | dead | Only tests instantiate it; `ConversionService.ts:9` hard-wires the browser client. |
| N-02 | `mock_conversion_client.ts` | dead | Re-exported only; no importer, including tests. |
| N-03 | All `mode === 'http'` / `mode !== 'embedded'` branches (eight sites, 1.3) | dead | `mode` is the constant `'embedded'`. |
| N-04 | Help-drawer diagnostics: `SystemStatsPanel.tsx`, `TelemetryPanel.tsx`, `TelemetryService.ts`, `useSystemStats.ts` | dead | Rendered only under `hasBackendDiagnostics`; stats polling interval is 0. |
| N-05 | `ConversionHistoryPanel.tsx` (`/api/sessions`) | dead | Same gate; route absent from `converter-server`. |
| N-06 | Backend restart: handlers in `useBackendRestartDialog.ts`, three `ConfirmDialog` instances, `ConfirmDialog.tsx`, `restartBackend` | dead | Button is inside N-04; the browser client has no `restartBackend`. The Escape handler moves to P-06. |
| N-07 | Health polling and offline banner: `useHttpRuntimeHealth.ts` effects 1-2, `pingBackendHealth`, `resolveHealthEndpoint`, `apiHealthLabel`, `showOfflineBanner` | dead | Embedded early returns; health status never becomes `fail`. The ETA countdown moves to P-27. |
| N-08 | `VoicePreviewButton.tsx` (`/api/voice-preview`) | dead | Rendered only when not embedded; route absent from `converter-server`. |
| N-09 | Engine select, engine detail card, auto-engine comparison, legacy voice select, voice-loading hints, duration estimate (`/api/voices`, `/api/estimate`) | inert | Only Piper is selectable; `submit` ignores `voice`; the fetches are behind the embedded early returns. |
| N-10 | Advanced options the browser client rejects (twelve fields, 1.3) | inert | `BrowserConversionClient.ts:66-84` throws when any is set. |
| N-11 | Advanced options the browser client ignores (28 fields, 1.3) | inert | `submit` never reads them. |
| N-12 | Edge in the browser: disabled Edge options and the "allow online fallback" checkbox | inert | `BrowserConversionClient.ts:88-96`; Edge options rendered `disabled`. |
| N-13 | Tauri: `lib/tauri.ts`, `UpdateBanner.tsx`, Tauri effects in `useNativeStartup.ts`, startup log and engine error panels, path uploads, download interception, OS notification, native menu listeners, `desktop_*.css`, `public/log-viewer.html` | dead | All behind `isTauri()`; no Tauri project in the repository; D16. |
| N-14 | Capacitor: `capacitor.config.ts`, `@capacitor/*`, `build:mobile`, `cap:*`, `.env.mobile` | dead | No import in `web/src`; no native project directories; D16. |
| N-15 | Dependency `@mintplex-labs/piper-tts-web` | dead | No import anywhere in `web/`. |
| N-16 | Vite `/api` proxy, `VITE_API_BASE` env files, `config.ts:API_BASE_URL`, `ENABLE_SSE`, `POLL_INTERVAL_MS`, `resolveApiUrl` | dead | Every consumer is in N-01…N-09 or N-13. |
| N-17 | `BookCoverCard.tsx` | dead | Imported only by its test. |
| N-18 | `UiHealthPanel.tsx` and the `uiIssueMonitor.ts` recorder | panel dead; recorder unread | Panel imported only by its test; the recorder writes `localStorage` and the console and nothing displays it. |
| N-19 | `public/index.html` | dead | Duplicate entry with a development script path; unreferenced. |
| N-20 | CLI reproduction command (`utils/cliReproduction.ts`, status toolbar and downloads blocks) | dead | Needs `localPath`, set only by Tauri uploads. |
| N-21 | ZIP download, log preview, log download | dead | The browser produces only `chapter-N.mp3`. |
| N-22 | UI for snapshot fields the browser never sets: cover image, detected language, current chapter, status hint, engine status, speed, parallelism meter, server raw log, chapter retry details | dead | Fields absent from the snapshot built in `BrowserConversionClient.ts` / `BrowserJobExecution.ts`. |
| N-23 | PDF in the picker (`accept="…,application/pdf"`, `.pdf` extension) | inert (inferred) | Only `inspect_epub` exists in `converter-wasm`. |
| N-24 | `EmbeddedConverter.previewChapter`, `convertToAudio`, `embeddedCapabilities` | dead | Referenced only by their own test. |
| N-25 | `downloadLatencyEvidence` | dead | No caller; recording and serialisation are carried in P-44. |
| N-26 | Legacy unversioned audio acceptance (`accept_audio` path for a synthesis that returns bare bytes) | open (Q-10) | `platformRuntime` returns receipts whenever the model is prepared; stored jobs without receipts may exist in user browsers **(unverified)**. |

---

## Part 3 — Decision record

### 3.1 Context

The deployed web client is a React/Vite single-page application whose only
live conversion path is already in the browser (1.1). It still carries a
second, unreachable architecture: an HTTP client, server diagnostics, a
desktop shim and a mobile wrapper (1.3). The image that serves it runs
`converter-server` mainly as a static file server; the API that server exposes
accepts only Edge selections (`http_conversion_routes.rs:
validate_server_preferences`) and is not called by the page.

`ruby_app/rails_gateway` is a Rails application (`Gemfile`: `rails ~> 8.1.4`) in API-only mode
(`config/application.rb`: `config.api_only = true`, `ApplicationController <
ActionController::API`). It has no asset pipeline gem (no Propshaft,
importmap, Turbo, Stimulus, Sprockets or bundling gem in `Gemfile`), no
application views (`app/views` holds only mailer layouts), SQLite with the
Solid adapters, Puma behind Thruster, two request test files (four tests) and
one sanitizer test file. Its routes delegate health, metadata and server-side book conversion to
`converter-server` through `app/services/rust_client.rb`. The
`rails/test_unit/railtie` require is commented out in `config/application.rb`
while `.github/workflows/ruby-rust-integration.yml` runs `bundle exec rails
test`; whether that command currently executes the tests was not checked
**(unverified)**.

The Hugging Face Space is published automatically:
`.github/workflows/sync-hf.yml` runs after "Post-merge validation" succeeds on
`master`, builds an allowlisted snapshot with `scripts/hf_snapshot.rb`
(`FILES` and `TREES` include `web` and `crates`, not `ruby_app`; the tracked
`web/src/wasm/converter_wasm_bg.wasm` is a required input) and then polls
`https://pi1704-epub-to-mp3.hf.space/api/health`.
`.github/workflows/hf-snapshot-regression.yml` rebuilds the image from that
snapshot and asserts the health and contract JSON, `/app/web/dist/index.html`,
every referenced JS/CSS asset, the `0.0.0.0:7860` listener and the absence of
`.onnx` files. Any merge that changes `Dockerfile` therefore changes the public
Space, which is why the cutover is a separate PR-H.

### 3.2 Decision

Evolve `ruby_app/rails_gateway` into the web client. Rails renders the
interface and serves static runtime files. The browser keeps doing all
conversion, storage and playback. PR-G builds this beside `web/` and changes
nothing that the Space deploys.

**Rails rendering, routes and server role**

- Switch the gateway to full-stack rendering: `config.api_only = false`,
  `ApplicationController < ActionController::Base`. The preferences form uses
  Rails CSRF protection, which needs the cookie session and therefore a secret
  key base (Q-12). Locale and theme themselves are plain cookies.
- One document. The three tabs stay in a single page at `/` and are switched
  by a Stimulus controller, exactly as React keeps all panels mounted and
  toggles `hidden` (`AppView.tsx`). Reason: the WASM session, the Piper worker
  and the `<audio>` element must survive tab changes. `?tab=progress` and
  `?tab=downloads` are accepted for deep links. No new screen is introduced.
- Routes:

  | Route | Controller#action | Purpose |
  | --- | --- | --- |
  | `GET /` | `workspace#show` | The whole interface: layout, top bar, hero, help drawer, three tab panels, `<template>` fragments. |
  | `PATCH /preferences` | `preferences#update` | Stores `locale` and `theme` cookies (`auto` clears them) and redirects back; submitted by Turbo forms in the top bar. |
  | `GET /up` | `rails/health#show` | Process liveness. |
  | `GET /api/health`, `GET /health` | `health#show` | Local JSON `{"status":"healthy","contract_version":"1","backend":"rails"}`; keeps the URL polled by `sync-hf.yml` valid before and after cutover. |
  | existing `/api/metadata`, `/books…` | unchanged controllers | Server-side compatibility API. Mounted only when `RUST_CONVERTER_URL` is set (Q-02). Not used by the interface. |

- Because jobs never reach the server, Rails cannot render job lists,
  progress, the reader or downloads from data. It renders their **markup and
  strings**: static structure server-side, repeating rows as `<template>`
  elements that Stimulus controllers clone and fill from browser state.
- Server-side responsibilities, complete list: HTML and localisation; locale
  and theme negotiation; static delivery of controllers, the runtime tree,
  `sample.epub`, manifest and icons with correct content types and cache
  headers; a Content-Security-Policy; health. Rails stores nothing about
  books, jobs or audio, and no book byte is uploaded.
- `converter-server` has no role in the new web's runtime and is not in the
  new image (Q-01). It remains a separate product surface maintained under
  D14. The gateway's existing delegation code is kept behind
  `RUST_CONVERTER_URL` so the other PR and `scripts/rails_rust_e2e.sh` are not
  broken by PR-G.

**Hotwire scope (D33)**

- Turbo Drive for the few server round trips (preferences form). Turbo Frames
  are not used for tab content, for the reason above.
- Stimulus controllers own presentation and user intent only. They subscribe
  to one module-level store and never hold conversion state themselves.

### 3.3 Asset pipeline and the WASM build (D34)

The gateway uses no asset pipeline today, so nothing constrains the choice;
the requirements do:

1. `wasm-bindgen --target web` output, Emscripten's phonemizer and ONNX
   Runtime Web all locate sibling files by **relative URL**
   (`import.meta.url`, `locateFile`, `env.wasm.wasmPaths`); the React build
   already keeps them un-hashed under `/tts/`
   (`BrowserPiperRuntime.ts:bundledAssets`, `scripts/prepare-tts-runtime.mjs`).
2. Module workers do not use the page's import map.
3. The runtime image should need neither Node nor a Rust toolchain.

Decision: two delivery paths.

- **Page code: Propshaft + importmap-rails + turbo-rails + stimulus-rails.**
  Controllers and first-party modules are plain ES modules, digested by
  Propshaft and pinned in `config/importmap.rb`. Turbo and Stimulus are
  vendored by importmap. No bundler and no transpiler. Modules carry JSDoc
  types and are checked with `tsc --noEmit --checkJs` in CI.
- **Conversion runtime: one generated, un-digested tree served from
  `public/runtime/<runtime-id>/`.** Contents: `wasm/converter_wasm.js`,
  `wasm/converter_wasm_bg.wasm`, `workers/piper_worker.js` and its relative
  imports, `tts/` (ONNX Runtime Web ES module and `ort-wasm-simd-threaded`
  `.mjs`/`.wasm`, `piper_phonemize` `.js`/`.wasm`/`.data`). `<runtime-id>` is
  the SHA-256 of the tree; it is written to `config/runtime_manifest.json`,
  exposed to the page as a `<meta>` base URL, and gives immutable caching
  without renaming files. The tree and the manifest are gitignored.

Build, without committing generated files:

- `scripts/build_web_wasm.sh` gains an output-directory parameter (default
  remains `web/src/wasm` until React is deleted). The existing
  `wasm-bindgen`-version check against `Cargo.lock` is kept.
- A small `browser_runtime/package.json` with lockfile inside the gateway
  pins exactly the two browser packages React pins today
  (`onnxruntime-web` 1.31.1, `@diffusionstudio/piper-wasm` 1.0.0); a build
  script copies the needed files into the tree, as
  `prepare-tts-runtime.mjs` does now.
- **CI:** a new `rails-web` job in `ci.yml` installs the pinned tools with
  mise, adds the `wasm32-unknown-unknown` target, builds the runtime tree and
  runs the tests in 3.9. A new `rails` change scope (paths `ruby_app/`,
  `crates/converter-wasm/`, shared core, the build script) gates it and is
  added to `pr-gate`.
- **Docker:** build `ruby_app/rails_gateway/Dockerfile` with the repository root
  as its context so the Rust stage can copy `crates/`. Stages: (1) Rust: copy `Cargo.toml`,
  `Cargo.lock`, `crates`, `native`, `benches` (the workspace manifest lists
  them all), build `converter-wasm` for `wasm32-unknown-unknown` with
  `--locked`, run the `wasm-bindgen` CLI pinned to the `Cargo.lock` version;
  (2) Node: `npm ci` in `browser_runtime/` and assemble `tts/`; (3) Ruby
  build: `bundle install`, copy the tree, `assets:precompile`; (4) final Ruby
  slim image with gems, application, `public/assets` and `public/runtime`.
  PR-G validates the gateway image in `rails-image-regression.yml`. PR-H
  owns the production cutover of the root `Dockerfile`.

### 3.4 Conversion runtime without React

The React services are already framework-free classes and functions; only the
hooks and components depend on React. The split:

| Concern | Today | New home |
| --- | --- | --- |
| Segment order, provider policy, cancellation, accepted audio, chapter MP3 | `ConversionSession` | unchanged Rust export |
| MP3 encoding, TTS catalog, cache-identity material | `encode_pcm_f32_mp3`, `tts_catalog_json_v2`, `tts_request_cache_material_v2` | unchanged Rust exports |
| Reader document: sanitised chapter markup, pagination, search and audio highlight ranges | `reader_pagination.ts`, `reader_markup.ts`, `reader_highlighting.ts`, `utils/readerSanitizer.ts` | new additive Rust exports; the controller only inserts the result into a shadow root (Q-03) |
| Job state transitions, progress and ETA arithmetic | `conversion_state.ts`, `conversion_eta.ts`, parts of `BrowserJobExecution.ts` | `rt:workspace_store` first; candidates for Rust after parity (Q-03) |
| Piper inference | `BrowserPiperWorker.ts`, `BrowserPiperRuntime.ts` | `worker:piper_worker` — plain module worker, same version-2 message contract (`requestId`, `modelId`, `modelRevision`, `voice` → MP3 plus receipt) |
| Worker client, deadline, cancellation by termination | `BrowserPiper.ts` | `rt:piper_client` |
| Job loop I/O, receipts, byte ranges, object URLs | `BrowserJobExecution.ts`, `BrowserConversionClient.ts` | `rt:job_execution`, `rt:conversion_client` |
| IndexedDB store and restore validation | `BrowserJobStore.ts`, `BrowserJobRepository.ts`, `BrowserAudioIdentity.ts` | `rt:job_store`, `rt:job_repository`, `rt:audio_identity` |
| Model install and verification | `BrowserModelInstallation.ts`, `BrowserModelIntegrity.ts` | `rt:model_installation`, `rt:model_integrity` |
| Browser speech | `BrowserNativeSpeech.ts`, `NativePlaybackPresentation.ts` | `rt:native_speech` (publication through the same store instead of `useSyncExternalStore`) |
| Application state: phase, log, queue, batch, tab intent | `useConversion*` hooks, `useApplication*`, `useWorkspace*` | `rt:workspace_store`: one module-level singleton that emits change events |

ONNX Runtime Web and the phonemizer stay JavaScript/WASM libraries loaded by
the worker from the runtime tree; moving inference into `converter-wasm` is
out of scope. `converter-wasm`'s existing exports are used as they are; PR-G
may add exports and does not change or remove any.

Where state lives (unchanged names, so both clients can read each other's
data during the transition and after a rollback):

| Store | Name | Content |
| --- | --- | --- |
| IndexedDB | database `ebook-tts.jobs.v1`, version 1, store `jobs`, key `jobId` | job snapshot, document, preferences, policy state, listening position, audio blobs with ranges, receipts and cache identity |
| OPFS | directory `piper/` | `<model>.onnx`, `<model>.onnx.json` |
| localStorage | `ebook-tts.preferences.v1`, `epub-to-mp3:reader-prefs`, `epub-to-mp3:player-speed`, `epub-to-mp3:player-pos:<jobId>`, `ebook-tts-hidden-recent`, `ebook-tts-hidden-resumable`, `ebook-tts-pending-batch`, `ebook-tts-cache:<jobId>` | preferences, hidden ids, pending batch, per-job resume cache |
| Cookies (new) | `locale`, `theme` | lets Rails render the right language and theme on the first byte; seeded once from `ebook-tts-locale` / `ebook-tts-theme` |
| Memory | `rt:workspace_store`, selected-book map, latency observations | lost on reload, as today |

The IndexedDB version is **not** bumped while React can still be deployed.

### 3.5 Model installation (D19)

- The only trigger is the install button (P-13). No preload, no install on
  submit; a job whose model is missing fails with the existing "install the
  model before converting" message.
- Artifacts, sizes and SHA-256 come from the Rust catalog
  (`tts_catalog_json_v2`); download, staging under a temporary name, checksum
  verification and publish-or-restore follow `installFaberArtifacts`. The
  download goes from the browser to the catalog URL (today Hugging Face
  `rhasspy/piper-voices`).
- Storage is OPFS `piper/`. Removal is not offered today and is not added.
- The image and the repository contain no weights. The image regression check
  keeps the existing "no `*.onnx` under the application and data roots"
  assertion, and a Rails test asserts none exists under `public/` or `app/`.
- No paid provider is involved at any point.

### 3.6 Cross-origin isolation and headers

The current application does not rely on cross-origin isolation (1.1). The new
web keeps that:

- **No COOP/COEP headers.** ONNX Runtime stays at one thread. This keeps the
  model download from another origin and the Space's embedding in
  `huggingface.co` working without `crossorigin` gymnastics. A test asserts
  the headers are absent and that synthesis runs with
  `crossOriginIsolated === false`.
- Required headers, each with a test: `Content-Type: application/wasm` for
  `.wasm`, a JavaScript type for `.js` and `.mjs` (the reason
  `web/plugins/onnxRuntimeModule.ts` exists for the dev server),
  `Cache-Control: public, max-age=31536000, immutable` for `/assets/*` and
  `/runtime/<id>/*`, `no-cache` for HTML.
- A Content-Security-Policy is introduced: `default-src 'self'`; `script-src
  'self' 'wasm-unsafe-eval'`; `worker-src 'self' blob:`; `media-src 'self'
  blob:`; `img-src 'self' data: blob:`; `connect-src 'self'` plus the hosts
  the model download needs. The exact download hosts after Hugging Face's
  redirect are **unverified** and are established in slice 6; the policy
  starts in report-only mode until they are known.
- `frame-ancestors` must allow `https://huggingface.co` so the Space page can
  embed the application.

### 3.7 Hugging Face Space container

- One container, one exposed port, two processes started by one command:
  Thruster on `0.0.0.0:7860` in front of Puma on a loopback port (the gateway
  already starts through `bin/thrust`; Thruster's port settings were not
  checked in this repository — **unverified**). `EXPOSE 7860`; the health check requests
  `/api/health`.
- Image contents: Ruby runtime, gems, the Rails application, precompiled
  `public/assets`, the generated `public/runtime/<id>/`, `sample.epub`,
  manifest and icons. Not in the image: Node, the Rust toolchain,
  `converter-server`, ffmpeg, `web/`, model weights.
- Runs as a non-root user (the gateway `Dockerfile` already uses uid 1000).
- Server state: none required by the interface. SQLite remains only for the
  optional compatibility API; its files go under `PERSISTENT_ROOT` when
  writable, otherwise a container-local directory. Whether the Space has
  persistent storage enabled is **unverified** (Q-11).
- Rails production needs a secret key base; how the Space provides it is
  Q-12.

### 3.8 Internationalisation

- `config/locales/pt-BR.yml` and `config/locales/en.yml`, generated once from
  the React dictionaries with the same key hierarchy. Function-valued entries
  become interpolations (`%{title}`) and Rails pluralisation.
- Locale selection: `locale` cookie, else `Accept-Language`, else English —
  the server-side equivalent of `resolveLocale`. `<html lang>` is `pt-BR` or
  `en-US` as today.
- Strings used by JavaScript are emitted by Rails: inside `<template>`
  fragments and `data-*` values, plus one JSON block for message patterns.
  Controllers contain no user-facing literals. The inline `locale === 'pt' ?
  … : …` literals in `StreamingAudioPlayerView.tsx`, `FormEngineOptions.tsx`
  and `useApplicationState.ts` become real keys.
- Error messages thrown in English by the services today
  (`BrowserConversionClient.ts`, `BrowserJobStore.ts`, …) keep their literal
  text; localising them is a separate change (Q-13).
- Parity is enforced by P-41. Strings that belong only to N-rows are not
  migrated once the owner confirms those rows.
- Locales stay at two; Spanish is not added by this ADR (Q-14).

### 3.9 Test strategy

| Layer | What it proves | Tooling | Where it runs |
| --- | --- | --- | --- |
| Rails integration tests | routes, status codes, health JSON, headers of 3.6, locale and theme negotiation, presence of landmarks and templates, i18n key parity, no weights under `public/` | Minitest (`ActionDispatch::IntegrationTest`); `rails/test_unit/railtie` re-enabled | `rails-web` job; `ruby-rust-integration.yml` |
| JS/WASM contract tests | freshly built exports, catalog, receipts, session resume, worker message contract, store/repository/execution logic with the in-memory store | `node --test`, as `web/scripts/*.node-tests.mjs` do today; ports of `BrowserConversionClient.test.ts`, `BrowserJobLifecycle.test.ts`, `BrowserModelInstaller.test.ts`, `BrowserNativeSpeech.test.ts`, `BrowserAudioIdentity.test.ts`, `LatencyObservation.test.ts` | `rails-web` job |
| Rails system tests | every P-row acceptance in a real headless Chromium with the real WASM; synthesis through a fixture worker that returns fixed audio, the technique `verify-browser-tts.mjs` uses | `ActionDispatch::SystemTestCase`, Capybara | `rails-web` job |
| Real-model browser run | actual Faber synthesis end to end after an explicit, checksum-verified model download | same system tests with the fixture disabled | separate workflow modelled on `browser-runtime.yml` (`workflow_call` / dispatch, part of post-merge validation) |
| Image regression | `ruby_app/rails_gateway/Dockerfile` builds; health; root HTML; every referenced asset and the runtime tree served with the right type; `0.0.0.0:7860`; no `.onnx` | shell, as `hf-snapshot-regression.yml` | new workflow, PR-G; replaces the React assertions in PR-H |

Rules: system and JS tests run with **at most two workers**, on the Mac and in
CI (`parallelize(workers: 2)` as an upper bound; `node --test
--test-concurrency=2`). The first slice must show a non-zero count of executed
Rails tests. The React `web` job in `ci.yml` keeps running unchanged until
PR-H. Tests assert observable behaviour (DOM, storage, bytes) at the seam that
changed, in line with the "cover each changed behavior at its failing seam"
rule in `CODING_STANDARDS.md`.

### 3.10 Implementation slices

Each slice is mergeable alone, leaves the React deployment untouched and ends
with its acceptance automated.

| # | Slice | Rows | Acceptance |
| --- | --- | --- | --- |
| 1 | Shell and asset pipeline serving WASM | P-01, P-02, P-03, P-06, P-45 | `GET /` renders the shell in both locales; theme and locale forms work; the runtime tree is built in CI and Docker from Rust with nothing generated committed; a system test initialises the WASM module and reads the TTS catalog; header tests of 3.6 pass; `ruby_app/rails_gateway/Dockerfile` image passes the image regression. |
| 2 | Book selection and inspection | P-08, P-09, P-10, P-11, P-16 (validation) | Choosing, dropping and the sample button queue books with title and author from `inspect_epub`; reorder and remove work; no network request carries book bytes. |
| 3 | Reader | P-30, P-31, P-32, P-33 | A selected book's chapters are readable, paginated and searchable with persisted preferences; hostile markup is neutralised. |
| 4 | Conversion and progress | P-04, P-05, P-07, P-14, P-15, P-16, P-17, P-18, P-19, P-20, P-22, P-23, P-24, P-25, P-26, P-27, P-28, P-29, P-34, P-35, P-36, P-44 | With the fixture worker a two-chapter book converts, survives a reload as interrupted, resumes, cancels; batch, skip and queue controls work; playback follows; the browser-speech fallback appears only after a provider failure. Cross-client storage compatibility (P-23) is proven against a database written by the React build. |
| 5 | Downloads | P-21, P-37, P-38, P-39, P-40 | Finished chapters play and download; older jobs are selectable; reset returns to setup. |
| 6 | Model installation | P-12, P-13 | Explicit install stores verified files in OPFS; the real-model workflow converts the sample; the CSP leaves report-only mode with the verified host list. |
| 7 | Internationalisation | P-41 | Key-set parity between locales and against React; no user-facing literal in controllers; both locales pass the system suite. |
| 8 | PWA and accessibility sweep | P-42, P-43 | Manifest and icons served at the existing paths; no service worker; role, name and keyboard assertions for every tab. |

Reader (3) precedes conversion (4) because the player and the fallback are
mounted inside the reader, as in `EbookReaderPanelView.tsx`.

### 3.11 Cutover criteria (PR-H) and rollback

"Full parity" (D7) is reached when all of the following hold:

1. Every P-row is either accepted by the owner with its automated check green
   on `master`, or explicitly rejected by ID.
2. Every N-row is confirmed by ID.
3. Storage compatibility is demonstrated in both directions (P-23) and the
   IndexedDB version is still 1.
4. The real-model browser workflow and the `ruby_app/rails_gateway/Dockerfile` image regression
   have passed in post-merge validation on the commit PR-H is based on.
5. The open questions in 3.15 are answered.

PR-H then, in one change: makes the Rails image the root `Dockerfile`; updates
`scripts/hf_snapshot.rb` (`FILES`, `TREES`, required inputs: add the gateway,
drop `web` and the tracked `.wasm`) and its tests; rewrites the assertions in
`hf-snapshot-regression.yml` (health JSON, no `/app/web/dist`, runtime tree
types); removes the `web` job, the `web/src/wasm` path from the `wasm` change scope in
`ci.yml`, the `cmp web/src/wasm/…` step and the web-only mise tasks; deletes `web/`; updates `docs/wasm-capability-
boundary.md`, `docs/agents/runtime-navigation.md` and `web`-referencing docs.
`/api/health` keeps answering 200 so the `sync-hf.yml` check needs no change.

Rollback:

- **Space:** dispatch `.github/workflows/rollback-hf.yml` with the last
  validated commit before PR-H; it rebuilds the Space from that commit, which
  still contains `web/` and the React `Dockerfile`.
- **Repository:** revert PR-H as one commit; because PR-G never modified
  `web/` or the root `Dockerfile`, the revert restores the React deployment
  exactly.
- **User data:** unchanged store names and schema version mean a browser that
  used the Rails client keeps its jobs, audio, model and preferences under
  React.

### 3.12 Consequences

- The web client becomes server-rendered HTML with small controllers; React,
  Vite, the TypeScript build and the unreachable code listed in 1.3 disappear
  at cutover.
- First-party browser code moves from TypeScript to checked JavaScript. Types
  remain as JSDoc; compile-time guarantees are weaker than today.
- The generated WASM stops being a reviewed, committed artifact for the web;
  every image and CI run builds it, which lengthens those builds and makes the
  pinned `wasm-bindgen` CLI a build-time requirement of the image.
- The Space image no longer contains `converter-server`; the public Space
  stops exposing `/api/convert` and related routes.
- Two web clients and two CI web jobs exist from the first PR-G slice until
  PR-H.
- The Rails layer is thin by design: any rule that affects conversion, audio
  or reading must be added to Rust, not to Ruby or a controller.
- ONNX inference stays single-threaded.

### 3.13 Alternatives considered

- **jsbundling-rails with esbuild for everything.** Keeps TypeScript and lets
  the services move almost verbatim, but keeps a bundler and its
  WASM/worker loader configuration as a permanent part of the gateway, which
  is what D33's Hotwire choice moves away from. Retained only as the fallback
  for the worker file if a third-party package cannot load as a native module
  (R-02).
- **Digest every runtime file through Propshaft.** Rejected: generated glue,
  Emscripten and ONNX Runtime resolve siblings by relative name; digesting
  would require patching generated code on every upgrade.
- **Tabs as separate Turbo pages.** Rejected: the session, worker and audio
  element would have to be kept alive across body replacement for no visible
  gain, and React already keeps all three panels mounted.
- **Keep `converter-server` in the image and proxy Rails to it.** Rejected for
  the interface: no live browser path calls it, it accepts only Edge, and it
  would add a second process, ffmpeg and a larger attack surface.
- **Enable COOP/COEP for multithreaded inference.** Rejected for now: not
  needed by current behaviour, complicates cross-origin model download and
  Space embedding, and has no measured benefit in the repository.
- **Commit the generated WASM into the gateway.** Excluded by D34.
- **Server-side conversion in Rails.** Excluded by D7 and by the project rule
  that conversion lives in Rust and runs on the client.

### 3.14 Risks

| ID | Risk | Mitigation |
| --- | --- | --- |
| R-01 | Rack's static server may not send a JavaScript type for `.mjs` or `application/wasm` for `.wasm` in this stack **(unverified)**. | Header tests in slice 1; register the MIME types explicitly if a test fails. |
| R-02 | `onnxruntime-web` and `piper_phonemize.js` may not be importable as native ES modules from a worker without a bundler **(unverified; `node_modules` was not installed)**. | Slice 1 spikes the worker first; fallback is bundling the worker file alone with esbuild in the Node build stage. |
| R-03 | Model download redirect hosts are unknown, so a strict `connect-src` could block installation. | CSP report-only until slice 6 records the real hosts. |
| R-04 | The Space is shown inside an iframe on `huggingface.co`; browsers may partition or block IndexedDB/OPFS there, separately from the direct `hf.space` URL. This already applies to React **(unverified)**. | System test for the storage-unavailable message; document the direct URL. |
| R-05 | `rollback-hf.yml` builds its snapshot with `rsync` of the whole checkout and force-pushes `main`, a different path from `hf_snapshot.rb` + `hf_push.sh` used by `sync-hf.yml`. A rollback after PR-H has never been exercised. | Dry-run the rollback against a scratch remote before PR-H merges. |
| R-06 | Porting the live modules of `web/src/services` (about 2,600 lines, excluding tests and the dead HTTP/mock files) to JavaScript can introduce regressions in receipt, byte-range and epoch handling. | Port the existing unit tests first and keep them green; move logic to Rust only after parity. |
| R-07 | Auto locale changes from `navigator.language` to `Accept-Language`; they can differ. | Accepted difference unless the owner objects (Q-06). |
| R-08 | Building the WASM in Docker requires the whole Cargo workspace context and a pinned CLI; image builds get slower. | Layer caching on `Cargo.lock`; measure in the image regression workflow. |
| R-09 | `bundle exec rails test` may currently run zero tests because the test railtie is commented out **(unverified)**. | Slice 1 re-enables it and asserts a non-zero count. |

### 3.15 Questions answered by the owner

The owner accepted the default, the first option, of every row on 2026-11-17.

| ID | Question | Options (default first) |
| --- | --- | --- |
| Q-01 | Ship the new Space image **without** `converter-server` (the public `/api/convert`, `/api/jobs…` routes disappear)? | yes / no, keep it as a second process |
| Q-02 | Keep the gateway's existing `/books…` and `/api/metadata` routes, mounted only when `RUST_CONVERTER_URL` is set? | yes / delete them in PR-G / keep always mounted |
| Q-03 | Reader document (sanitise, paginate, highlight) as new Rust/WASM exports from slice 3, per D33's wording? | yes, Rust in slice 3 / port the JavaScript first, move to Rust after cutover |
| Q-04 | Accept first-party browser code as JSDoc-checked JavaScript instead of TypeScript? | yes / no, use esbuild and keep TypeScript |
| Q-05 | Keep the three tabs in one document at `/` (no per-tab pages)? | yes / no, separate URLs |
| Q-06 | Accept `Accept-Language` as the "auto" locale source? | yes / no, detect in the browser and reload once |
| Q-07 | Saved-batch banner (P-19): today "resume" cannot find the books after a reload. | keep the banner with dismiss and "choose the files again" only / reproduce today's behaviour exactly / persist selected books in IndexedDB so resume works (new behaviour) |
| Q-08 | Share block (P-40) shares a `blob:` URL that only works in the same tab. | carry unchanged / drop it (becomes an N-row) / share the MP3 files through the Web Share API where supported (new behaviour) |
| Q-09 | PDF (N-23): remove `.pdf` from the picker so only EPUB is offered? | yes / no, keep offering it and show the per-file error |
| Q-10 | N-26: keep accepting stored jobs that have no synthesis receipts? | yes, keep the legacy path / no, mark such jobs interrupted |
| Q-11 | Is persistent storage enabled on the Space, and should the optional SQLite files live under it? | not needed, use container-local storage / yes, under `PERSISTENT_ROOT` |
| Q-12 | Secret key base on the Space. | add a `SECRET_KEY_BASE` Space secret / generate an ephemeral one at boot (a restart then invalidates forms that were already open, once) |
| Q-13 | Localise the English error messages thrown by the runtime modules? | no, keep literals for parity / yes, in slice 7 |
| Q-14 | Add Spanish to the web? | no, two locales as today / yes, after cutover |
| Q-15 | N-18: drop the unread UI-issue recorder together with its dead panel? | yes / no, keep recording to `localStorage` |
| Q-16 | Before PR-H, publish the Rails image to a second, private Space for a manual check? | yes / no, rely on the image regression and system tests |
| Q-17 | Confirm rows N-01 to N-25 as not carried over. | confirm all / list the IDs to keep |
