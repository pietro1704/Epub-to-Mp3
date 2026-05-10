# Audit findings — v0.4.0 release window

Four parallel sub-agents inspected the four major surfaces of the
project on 2026-05-10. Reports below are read-only — every entry is
**triage candidate**, not a shipped fix.

---

## CLI module

### Top 3 bugs

1. **`--no-cache` wipes the entire shared cache, not just the current book.**
   `python_app/main.py:672-674` calls `shutil.rmtree(self.cache_root)` before recreating only the current book's subdir. Failure: running `--no-cache` on book A while book B has cached parsed text destroys B's cache. In batch mode it nukes every prior book's cache mid-run.

2. **`_normalize_cli_args` short-circuits when a directory matches a stray token.**
   `python_app/convert:110-121` greedily joins tokens until `Path(candidate).exists()`. If the user types `convert downloads o louco de deus` and a directory named `downloads` exists in CWD, it stops at token 1 (the dir exists), recurses, and never reaches the fuzzy fallback at `convert:184` — opposite of the documented contract in CLAUDE.md.

3. **`_prepare_payload` ThreadPool retry path resubmits a future the executor may already be tearing down.**
   `python_app/src/converter.py:1342-1362` only checks `future.result(timeout=120)` per-task in submission order; one slow chapter blocks iteration for up to 360 s before completed-but-later chapters are read, and the resubmitted future may run after the executor exits the `with` block. Spurious "cannot be processed after 3 attempts" raised even when later futures completed cleanly.

### Top 3 perf wins

1. **`_handle_clear_cache` walks `output_dir.rglob("*")` calling `stat()` per file** (`main.py:3246-3249`) just to print MB. Multi-GB output dirs stall the confirmation prompt for seconds.
2. **`_fuzzy_find_book` runs `difflib.SequenceMatcher` O(query × file_tokens) per candidate** (`convert:72`). 500 EPUBs × 5 query tokens = ~2500 SequenceMatcher constructions per invocation. Cheap prefix/substring prune first would cut this 10–50×.
3. **`_resolve_batch_targets` sorts the entire tree before filtering by suffix** (`main.py:336-340`). Filter inside the generator + use `os.walk`.

### Security

- **Cache directory traversal via `Path(args.input_file).stem`** — `main.py:667,678`. Filename `../evil.epub` produces stem `..` and `cache_root / ".."` resolves outside the cache root. `temp_dir.mkdir(parents=True, exist_ok=True)` at line 680 then creates directories outside the cache. `_resolve_cache_dir` (line 3221) DOES sanitise — but this code path bypasses it.
- **No zip-bomb / decompression-ratio limit when reading EPUB** — `ebook_reader.py:1528,2829-2837` uses `archive.read(member)` on attacker-controlled members with no size cap. A crafted EPUB with 1 MB compressed → 10 GB inflated XHTML can OOM the CLI before any TTS work starts.
- **`shutil.rmtree` on user-derived paths in `_clear_cache_all` / `_handle_clear_cache_for_book`** with no verification that the resolved path stays under `PERSISTENT_ROOT`. Sharp edge for users running the CLI from `/`.

---

## Web frontend

### Top 3 bugs

1. **Stale-closure bug in cache writer.** `useConversionFlow.ts → ConversionService.saveStateWithQueue(jobId, fileNameRef.current, state)` captures `state` from the render where `runConversion` was created; SSE/poll updates dispatch fresh state but the cache writer keeps writing the initial snapshot. Resume-after-refresh loses progress (`chapterProgress`, `summary`, `etaSeconds`).
2. **SSE reconnect duplicates the appended-events stream.** `ConversionService.ts:950-965` `closeSource()` removes `chapter_update` but `connect()` only sets `onmessage` + re-adds `chapter_update`; on reconnect after the 25 s idle watchdog, `latestSnapshot` survives but the server may resend the full snapshot first as a delta — `appendSnapshotEvents` dedups via `seenEventsRef`, but `onSnapshot` is invoked twice with the same payload, triggering double `applySnapshotMeta` + redundant cache writes.
3. **HTTP fallback poll runs in parallel with SSE.** `useConversionFlow.ts:1161-1237` starts an independent `api.fetch` loop every 2 s whenever `phase === "polling"` while `pollWithEventSource` is still alive. Two transports race — the HTTP one may apply older snapshots, regressing `chaptersCompleted` / `progressPercent` mid-job.

### Top 3 perf wins

1. **`App.tsx` is a 1932-line god-component** with 17+ `useEffect`s and most state at the top. Every snapshot tick re-renders the full tree. Splitting `useConversionFlow` consumers into context + memoized child panels would cut render cost dramatically.
2. **`EbookReaderPanel.tsx:422` rewrites `shadow.innerHTML` on every `currentPage.html` or `renderedCss` change**, even when only `playback.segmentIndex` toggles. Memoise on stable `(chapterIndex, pageIndex)` and apply highlight via CSS variable / `data-` attribute mutation.
3. **`useConversionFlow.ts:806-813` `recentSpeed` memo lists `state.summary?.chapterProgress` as a dep** — every snapshot creates a new array, recomputing `adaptiveTolerances` and rebuilding `useCallback`s downstream.

### Security

- **`EbookReaderPanel.tsx:428` writes `shadow.innerHTML` with `currentPage?.html` and `renderedCss` straight from the `/api/jobs/{id}/fulltext` payload.** Shadow DOM does **not** sandbox script execution; attacker-controlled EPUB content runs in the same origin. Backend should sanitise via DOMPurify or server-side bleach before this lands in the DOM.
- **`new EventSource(streamUrl, { withCredentials: true })`** at `ConversionService.ts:970` sends cookies cross-origin to `API_BASE_URL`. CSRF-able SSE pattern unless the backend hard-pins CORS origin.
- **`normalizeAssetUrl` (`ConversionService.ts:372`)** trusts server-supplied `asset.url` / `chapter.downloadUrl` — `javascript:` and absolute external URLs surface as `<a href>` / `window.open(url, "_blank")` in `DownloadsPanel.tsx:237` and `ReadyDownloadsList.tsx:122`. No `https?:` allow-list.

---

## Desktop bundling (Tauri + PyInstaller + SwiftUI)

### Top 3 bugs

1. **Tauri shell port-reuse race spawns ghost sidecar.** `desktop/src-tauri/src/lib.rs:439-447`. If a stale `epub-to-mp3-server` from a previous crashed launch is still bound to 47860 (or another app squats the port), the Tauri shell skips spawn entirely and never owns the child PID. `MAX_RESTARTS` and crash recovery are dead. No PID file or process-name check.

2. **Sandboxed Release will not exec the embedded sidecar.** `ios/EpubToMp3/project.yml:48` + `Resources/EpubToMp3.entitlements`. Release ships `app-sandbox=true` with no `com.apple.security.cs.allow-unsigned-executable-memory` / `cs.disable-library-validation`. Bundled PyInstaller binary in `Contents/Resources/` is unsigned — `Process.run()` against an unsigned bundled exec from a hardened-runtime parent fails with EPERM. Debug works because Debug entitlement disables sandbox.

3. **PyInstaller onefile + `runtime_tmpdir=None` wipes `.jobs/` across relaunches.** `desktop.spec:101` + `desktop_main.py:12-15`. Memory `project_desktop_sidecar.md` already flagged this; spec still has `runtime_tmpdir=None`. Any feature that reads `.jobs/` from `_root` regresses.

### Top 3 perf wins

1. **First-launch ffmpeg download blocks startup before uvicorn binds.** `desktop_main.py:57-71`. The 300 s startup poll runs `setup_ffmpeg()` synchronously; the port stays closed for ~30 s. Defer to a thread after `uvicorn.run` binds, or ship ffmpeg inside the PyInstaller `binaries=[]` (currently empty, `desktop.spec:11`).

2. **PyInstaller onefile re-extracts ~60 MB to `_MEIPASS` every launch.** `desktop.spec:88-102`. Switching to onedir (`COLLECT`) cuts cold start from seconds to ~200 ms and eliminates the wipe of resolved data dirs. UPX (`upx=True`) further slows macOS launch — Gatekeeper rescans.

3. **Sidecar log forwarding emits one IPC event per uvicorn access-log line.** `lib.rs:147-165`. Under high SSE chatter this floods the webview event queue. Batch (e.g. 50 ms windows) and drop emit when the logs window is hidden.

### Security

- **`tauri.conf.json:24-26` — `csp: null`** disables Tauri's CSP entirely. Combined with `withGlobalTauri: true`, any XSS via book metadata reaches privileged commands (`pick_books`, `open_log_window`).
- **`SidecarManager.swift:206-207` — `INADDR_ANY` bind for free-port discovery.** Briefly binds 0.0.0.0; benign on close (uvicorn binds 127.0.0.1 afterwards), but should use `INADDR_LOOPBACK` for symmetry.
- **Updater single point of compromise.** `tauri.conf.json:48` endpoints points at `github.com/.../latest/download/latest.json` over HTTPS only. Mitigated by minisign pubkey, so acceptable — flag for awareness.

---

## Hugging Face Spaces integration

### Top 3 bugs

1. **Dockerfile uses non-existent `node:26-slim`.** `Dockerfile:2`. Latest Node LTS is 22; tag `node:26` doesn't exist on Docker Hub. Any HF rebuild from a clean cache fails at the frontend stage. Compounded by `npm install --legacy-peer-deps` (line 7) silently mutating lockfile state.

2. **Dead `/tmp/output` directory created, never used.** `Dockerfile:44`. HF persistent volume is `/data/epub-to-mp3/output` (`paths.py:151`); the `/tmp` mkdir masks an old assumption.

3. **`MODELS_DIR` rooted at `PROJECT_ROOT`, not `/data`.** `paths.py:186`. On HF, models (Piper, Coqui) get re-downloaded every container rebuild because the model dir lives inside the ephemeral image rootfs, not the persistent volume — first-conversion pt-BR cold start always re-fetches Piper.

### Top 3 perf wins

1. **Kokoro pre-warm waits 10 s blindly.** `hf_app.py:91`. Replace with readiness signal or run pre-warm inline in lifespan before yielding. On HF cold start the user can hit `/api/convert` before Kokoro is ready, forcing the first chapter onto Edge-only.
2. **`_hf_keepalive` initial delay only 10 s + 600 s loop.** `server.py:1781,1790`. HF idle threshold is ~15 min — keep-alive doesn't update job activity, so `_job_watchdog` may flag jobs as stalled while keep-alive succeeds. Hop interval to 540 s.
3. **48 h TTL + 60 s cleanup interval scans every job every minute** on a sleep-prone Space. `server.py:268,274`. Raise interval to 300 s; biggest latency win is fixing `MODELS_DIR` (above).

### Security

- **`/api/outputs/{job_id}/{filename}`** is path-traversal safe (`_validate_job_id` + `_safe_leaf_name` + `rglob` filtered to `path.name == safe_filename`). OK.
- **No auth on any endpoint.** Public demo by design — but no per-IP throttling, anyone can enqueue jobs and consume the shared egress quota. Rate-limit middleware is absent.
- **CORS `allow_credentials=True` with broad regex.** `server.py:316-326`. Permits any private-LAN origin with credentials. Unexploitable from public web (regex excludes public hosts) but a LAN attacker on the host network can drive the API with cookies.
- **Upload limit enforced AFTER `await file.read()` loads payload into RAM.** `MAX_UPLOAD_MB=100`, `routes_uploads.py:109`. Concurrent 99 MB uploads OOM the 16 GB Space.
- **HF_TOKEN handled correctly** — `sync-hf.yml:70-87` uses HTTPS-with-token via `insteadOf`; not echoed.
