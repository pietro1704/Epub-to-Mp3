"""Upload route handlers.

Extracted from server.py to reduce its line count.  All server-level globals
(_pending_uploads, _pending_lock, uploads_dir, MAX_UPLOAD_BYTES, etc.) are
accessed via lazy imports inside each handler to avoid circular imports.
"""

from __future__ import annotations

import hashlib
import time
import uuid
from pathlib import Path

from fastapi import APIRouter, BackgroundTasks, File, HTTPException, UploadFile
from fastapi.responses import FileResponse

router = APIRouter(prefix="/api", tags=["uploads"])


def _precache_uploaded_book(upload_path: Path, book_title: str, book_author: str) -> None:
    """Pre-cache parsed chapters after the upload response returns."""
    from src.ebook_reader import EbookReader

    import python_app.server as _srv

    try:
        reader = EbookReader(str(upload_path))
        chapters_list = list(reader.get_chapters())
        if not chapters_list:
            return
        chapters_data = {
            "title": book_title,
            "author": book_author,
            "chapters": [
                {
                    "title": getattr(ch, "name", f"Chapter {i}"),
                    "text": getattr(ch, "text", ""),
                }
                for i, ch in enumerate(chapters_list, 1)
            ],
        }
        _srv.get_cache_manager().save_chapters_to_cache(upload_path, chapters_data)
    except Exception as cache_error:
        _srv.logger.warning(f"Failed to cache chapters during upload: {cache_error}")


@router.get("/uploads/{upload_id}/{filename}")
async def serve_uploaded_asset(upload_id: str, filename: str):
    """Serve a previously uploaded asset (e.g. cover image)."""
    import python_app.server as _srv

    path = _srv.uploads_dir / upload_id / filename
    if not path.exists():
        raise HTTPException(status_code=404, detail="File not found")
    return FileResponse(str(path))


@router.post("/uploads")
async def upload_ebook(background_tasks: BackgroundTasks, file: UploadFile = File(...)) -> dict:
    """Upload ebook ahead of conversion to extract metadata/cover."""
    from src.ebook_reader import EbookReader

    import python_app.server as _srv

    if file is None:
        raise HTTPException(status_code=400, detail="No file uploaded")

    raw_payload = await file.read()
    if _srv.MAX_UPLOAD_BYTES and len(raw_payload) > _srv.MAX_UPLOAD_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"File exceeds the {_srv.MAX_UPLOAD_MB} MB limit",
        )

    _srv._cleanup_pending_uploads()
    upload_id = f"{uuid.uuid4()}"
    upload_dir = _srv.uploads_dir / upload_id
    upload_dir.mkdir(parents=True, exist_ok=True)
    original_name = Path(file.filename or "ebook").name
    temp_path = upload_dir / original_name
    temp_path.write_bytes(raw_payload)
    file_hash = hashlib.sha1(raw_payload).hexdigest() if raw_payload else None

    book_title = Path(original_name).stem
    book_author = "Unknown Author"
    cover_url = None
    cover_mime = None
    cover_filename = None
    cover_path = None

    try:
        reader = EbookReader(str(temp_path))
        if reader.title:
            book_title = reader.title
        if reader.author:
            book_author = reader.author
        cover_blob = reader.extract_cover_image()
        if cover_blob:
            cover_filename = f"cover{cover_blob.extension}"
            cover_path = upload_dir / cover_filename
            cover_path.write_bytes(cover_blob.data)
            cover_url = f"/api/uploads/{upload_id}/{cover_filename}"
            cover_mime = cover_blob.media_type

    except Exception:
        pass

    with _srv._pending_lock:
        _srv._pending_uploads[upload_id] = {
            "file_path": str(temp_path),
            "file_name": original_name,
            "book_title": book_title,
            "book_author": book_author,
            "cover_filename": cover_filename,
            "cover_path": str(cover_path) if cover_path else None,
            "cover_mime": cover_mime,
            "file_hash": file_hash,
            "created_at": time.time(),
        }
        _srv._write_pending_upload_metadata(upload_dir, _srv._pending_uploads[upload_id])

    background_tasks.add_task(_precache_uploaded_book, temp_path, book_title, book_author)

    return {
        "uploadId": upload_id,
        "fileName": original_name,
        "bookTitle": book_title,
        "bookAuthor": book_author,
        "coverUrl": cover_url,
        "coverMimeType": cover_mime,
    }
