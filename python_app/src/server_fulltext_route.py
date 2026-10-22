# -*- coding: utf-8 -*-
"""Reader full-text reconstruction and chapter markup."""

from __future__ import annotations

from typing import Optional


def _build_fulltext_chapters_from_cache(_runtime, cached: dict) -> list[dict]:
    result = []
    for idx, ch in enumerate(cached.get("chapters") or [], 1):
        html = _runtime.sanitize_reader_html(ch.get("html") or _runtime.chapter_html_fallback(ch.get("text") or ""))
        result.append(
            {
                "index": idx,
                "name": _runtime._chapter_display_name(ch.get("title"), html, idx),
                "sourcePath": ch.get("sourcePath"),
                "text": ch.get("text") or "",
                "html": html,
                "css": _runtime.sanitize_reader_css(ch.get("css") or ""),
                "resources": ch.get("resources") or [],
                "footnotes": ch.get("footnotes") or None,
                "charCount": len(ch.get("text") or ""),
            }
        )
    return result


async def get_job_fulltext(_runtime, job_id: str) -> dict:
    """Return full text of all chapters before audio conversion starts.

    This allows the UI to display chapter text immediately, even before
    any audio segments are ready.

    Status codes:
        200 OK            — chapters available (from cache or freshly parsed).
        404 Not Found     — job_id does not exist at all.
        503 Service Unavailable — text extraction is still in progress (the
            client should retry shortly). Returned when the source file is
            still being uploaded or when parsing is happening on another
            worker; the UI uses this to show a "still extracting" message
            instead of a permanent error.
    """
    job_data = _runtime.jobs.get(job_id) or _runtime.job_manager.load_job(job_id)
    if not job_data:
        raise _runtime.HTTPException(status_code=404, detail="Job not found")

    cache_manager = _runtime.get_cache_manager()
    input_file = job_data.get("inputFile") or job_data.get("file_path")

    # 1) Validate the source path early — paths outside the allowed roots
    # (e.g. `/etc/passwd`) are a hard 404, never a retryable 503.
    source_path: Optional[_runtime.Path] = None
    source_path_invalid = False
    if input_file:
        try:
            source_path = _runtime._resolve_job_source_path(input_file, must_exist=False)
        except ValueError:
            source_path_invalid = True

    if source_path_invalid:
        raise _runtime.HTTPException(status_code=404, detail="Source file not found")

    # 2) Try cache — the conversion path may have already extracted the text
    # and the source file might be gone (e.g. uploaded file moved by the
    # cleanup task). The cache is keyed by file path/title, so we attempt to
    # resolve a path even if it no longer exists on disk.
    #
    # Narrow exception list: corrupt JSON, missing file, or unreadable
    # cache directory are expected and we just fall through to the parse
    # path. ANY other exception is unexpected — propagate so the caller
    # sees it instead of silently skipping the cache and re-doing the
    # whole parse (the v0.3.16 audit flagged this `suppress(Exception)`
    # as a real risk for hiding production bugs).
    if source_path is not None:
        try:
            cached = cache_manager.get_cached_chapters(source_path)
        except (_runtime.json.JSONDecodeError, OSError, KeyError, ValueError) as exc:
            _runtime.logger.warning(
                "Cache read failed for %s — falling back to fresh parse: %s",
                source_path,
                exc,
            )
            cached = None
        if cached and cached.get("chapters"):
            return {
                "jobId": job_id,
                "bookTitle": job_data.get("bookTitle", "") or cached.get("title", ""),
                "bookAuthor": job_data.get("bookAuthor", "") or cached.get("author", ""),
                "chapters": _runtime._build_fulltext_chapters_from_cache(cached),
            }

    # 3) Cache miss — we need the source file on disk to parse it. If the
    # file is missing AND the job is still running/pending, this is a
    # transient state (upload-in-progress, race with cleanup, etc.) and the
    # client should retry. Only return a hard 404 once the job is in a
    # terminal failed state with no source.
    state = (job_data.get("state") or job_data.get("status") or "").lower()
    if not input_file or source_path is None or not source_path.exists():
        if state in {"failed", "error", "cancelled", "canceled"}:
            raise _runtime.HTTPException(status_code=404, detail="Source file not found")
        raise _runtime.HTTPException(
            status_code=503,
            detail="Source file is not yet available; retry shortly",
        )

    # 4) Parse the ebook on demand and persist to cache so subsequent calls
    # are cheap.
    try:
        reader = _runtime.EbookReader(str(input_file))
        book_chapters = reader.get_chapter_structure(preserve_all=True)

        chapters = []
        for idx, chapter in enumerate(book_chapters, 1):
            chapter_text = getattr(chapter, "speech_text", None) or chapter.text or ""
            clean_text = _runtime.TextFormattingProcessor.strip_inline_markdown(chapter_text)
            chapter_html = _runtime.sanitize_reader_html((getattr(chapter, "raw_html", None) or "").strip())
            if not chapter_html:
                chapter_html = _runtime.sanitize_reader_html(_runtime.chapter_html_fallback(clean_text))
            chapter_css = _runtime.sanitize_reader_css(reader.extract_chapter_stylesheet(chapter))
            chapter_resources = reader.extract_chapter_resources(chapter)

            chapters.append(
                {
                    "index": idx,
                    "name": _runtime._chapter_display_name(chapter.name, chapter_html, idx),
                    "sourcePath": getattr(chapter, "source_path", None) or None,
                    "text": clean_text,
                    "html": chapter_html,
                    "css": chapter_css,
                    "resources": chapter_resources,
                    "footnotes": list(getattr(chapter, "footnotes", None) or []) or None,
                    "charCount": len(clean_text),
                }
            )

        if not chapters:
            # The book was parseable but produced no chapters — treat as
            # transient if the job is still running (rare race), otherwise
            # surface a 422 so the UI shows a permanent failure instead of
            # spinning forever.
            if state in {"failed", "error", "cancelled", "canceled"}:
                raise _runtime.HTTPException(
                    status_code=422,
                    detail="Could not extract any chapter from this file",
                )
            raise _runtime.HTTPException(
                status_code=503,
                detail="Chapter extraction in progress; retry shortly",
            )

        with _runtime.contextlib.suppress(Exception):
            cache_manager.save_chapters_to_cache(
                _runtime.Path(input_file),
                {
                    "title": job_data.get("bookTitle", ""),
                    "author": job_data.get("bookAuthor", ""),
                    "chapters": [
                        {
                            "title": chapter["name"],
                            "sourcePath": chapter["sourcePath"],
                            "text": chapter["text"],
                            "html": chapter["html"],
                            "css": chapter["css"],
                            "resources": chapter["resources"],
                            "footnotes": chapter["footnotes"],
                        }
                        for chapter in chapters
                    ],
                },
            )

        return {
            "jobId": job_id,
            "bookTitle": job_data.get("bookTitle", ""),
            "bookAuthor": job_data.get("bookAuthor", ""),
            "chapters": chapters,
        }
    except _runtime.HTTPException:
        raise
    except Exception as e:
        raise _runtime.HTTPException(status_code=500, detail=f"Failed to extract text: {str(e)}")
