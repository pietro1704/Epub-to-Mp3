# Legacy compatibility reference

Read this only when maintaining python_app/ or legacy server behavior.
These gotchas preserve compatibility; they do not define the Apple/product
runtime, authorize service execution, or require mirroring Rust features into
every legacy path. Inspect current code/configuration for defaults and commands.

## CLI input and cache safety

In python_app/main.py, preserve the resolution chain: _normalize_cli_args joins
loose multi-word tokens until a path resolves or an option starts;
_collect_files_from_path expands paths; _fuzzy_find_book supplies the fallback.
The fallback searches Downloads and CWD, strips accents, and tolerates typos
and directory-name noise (historically ratio >= 0.75 per token, >= 60% matched).

The query "convert downloads o loudo de deus --clear-cache" must resolve the
intended book rather than fall through to _clear_cache_all and clear every cache.
Cover unresolved names and cache scope with executable CLI regression tests.
Keep book inputs, models, caches, and outputs intact unless cleanup is authorized.

## Speech and structure

TextProcessor.apply_structural_speech_cues in python_app/src/ebook_reader.py
announces the TOC title. Suppress a substantive title (at least 10 characters
and two tokens) only when present in the first roughly four lines. Short/numeric
titles always announce unless the first line literally matches; incidental
digits and common words must not suppress an announcement.

Preserve NCX/nav hierarchy and anchor-sharing behavior. Check oversized
footnote/container chapters and duplicate content in parsing regressions.
Keep Portuguese book keywords, speech cues, regexes, and fixtures literal.

## Tests and failure handling

Use patch.object for constants captured at import time and patch.dict for
environment values read at call time. Never use importlib.reload in tests:
it creates new class identities and breaks tests that retain earlier imports.

The Python CLI converter and legacy server have separate orchestration paths.
For a compatibility change explicitly covering both, inspect converter.py and
server.py plus their helpers; test both affected paths.
Keep retries bounded when all engines fail and update activity during long work.
Historical audio validation used EXPECTED_WPM=200 and skipped short payloads
below 1500 characters to avoid false truncation; inspect current configuration
before changing those heuristics.

Legacy hosted keep-alive requests use localhost; public self-pings caused
rate limiting. TTL/budget cleanup must spare active jobs. Inspect paths.py and
the relevant job/cache helpers rather than copying historical deployment values.

Run Python/web checks through their actual mise tasks when those surfaces change.
Their tests cannot substitute for Swift XCTest or Rust runtime evidence.
