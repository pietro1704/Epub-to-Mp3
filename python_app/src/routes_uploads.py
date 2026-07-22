"""Upload route handlers.

Extracted from server.py to reduce its line count.  All server-level globals
(_pending_uploads, _pending_lock, uploads_dir, MAX_UPLOAD_BYTES, etc.) are
accessed via lazy imports inside each handler to avoid circular imports.
"""

from __future__ import annotations

import hashlib
import os
import shutil
import time
import uuid
from pathlib import Path

from fastapi import APIRouter, BackgroundTasks, File, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel

router = APIRouter(prefix="/api", tags=["uploads"])
_VALID_UPLOAD_ID_CHARS = frozenset("0123456789abcdef-")
_UPLOAD_READ_CHUNK_BYTES = 1024 * 1024


async def _stream_upload_to_path(
    upload: UploadFile, destination: Path, max_bytes: int, max_mb: int | None = None
) -> dict:
    """Copy an upload to disk while enforcing its limit incrementally."""
    total = 0
    digest = hashlib.sha1()
    try:
        with destination.open("wb") as output:
            while True:
                chunk = await upload.read(_UPLOAD_READ_CHUNK_BYTES)
                if not chunk:
                    break
                total += len(chunk)
                if max_bytes and total > max_bytes:
                    raise HTTPException(
                        status_code=413,
                        detail=f"File exceeds the {max_mb if max_mb is not None else max_bytes // (1024 * 1024)} MB limit",
                    )
                output.write(chunk)
                digest.update(chunk)
    except Exception:
        destination.unlink(missing_ok=True)
        raise
    return {"size": total, "sha1": digest.hexdigest() if total else None}


def _sha1_file(path: Path) -> str:
    """Hash a local file incrementally without retaining its contents."""
    # lgtm [py/path-injection] The caller validates this path against fixed local roots.
    resolved = path.resolve(strict=True)
    allowed = any(
        os.path.commonpath((str(root), str(resolved))) == str(root)
        for root in _allowed_local_source_roots()
    )
    if not allowed:
        raise ValueError("Local source path is outside allowed roots")

    digest = hashlib.sha1()
    # lgtm [py/path-injection] `resolved` passed the fixed-root check above.
    with resolved.open("rb") as source:
        for chunk in iter(lambda: source.read(_UPLOAD_READ_CHUNK_BYTES), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _validate_upload_id(upload_id: str) -> str:
    value = str(upload_id or "")
    if not value or any(ch.lower() not in _VALID_UPLOAD_ID_CHARS for ch in value):
        raise HTTPException(status_code=400, detail="Invalid upload ID")
    return value


def _allowed_local_source_roots() -> tuple[Path, ...]:
    roots = [Path.cwd(), Path.home(), Path("/tmp"), Path("/private/tmp"), Path("/var/folders")]
    if Path("/Volumes").exists():
        roots.append(Path("/Volumes"))
    return tuple(root.resolve() for root in roots if root.exists())


def _resolve_allowed_local_source(raw_path: str) -> Path:
    import python_app.server as _srv

    candidate = Path(str(raw_path or ""))
    if not candidate.is_absolute():
        raise HTTPException(status_code=400, detail="Invalid file path")
    if candidate.is_symlink():
        raise HTTPException(status_code=400, detail="Symlinks are not supported")
    for root in _allowed_local_source_roots():
        try:
            return _srv._resolve_path_within_root(root, candidate, must_exist=False)
        except ValueError:
            continue
    raise HTTPException(status_code=400, detail="File path is outside allowed local roots")


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

    safe_upload_id = _validate_upload_id(upload_id)
    safe_name = Path(filename).name
    if safe_name != filename or not safe_name:
        raise HTTPException(status_code=400, detail="Invalid filename")
    uploads_root = _srv._resolve_relative_path_within_root(
        _srv.uploads_dir, safe_upload_id, must_exist=True
    )
    path = _srv._resolve_relative_path_within_root(uploads_root, safe_name, must_exist=False)
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

    _srv._cleanup_pending_uploads()
    upload_id = f"{uuid.uuid4()}"
    upload_dir = _srv._resolve_relative_path_within_root(
        _srv.uploads_dir, upload_id, must_exist=False
    )
    upload_dir.mkdir(parents=True, exist_ok=True)
    original_name = Path(file.filename or "ebook").name
    temp_path = _srv._resolve_relative_path_within_root(upload_dir, original_name, must_exist=False)
    try:
        upload_result = await _stream_upload_to_path(
            file, temp_path, _srv.MAX_UPLOAD_BYTES, _srv.MAX_UPLOAD_MB
        )
    except HTTPException:
        shutil.rmtree(upload_dir, ignore_errors=True)
        raise
    file_hash = upload_result["sha1"]

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
            cover_path = _srv._resolve_relative_path_within_root(
                upload_dir, cover_filename, must_exist=False
            )
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


class LocalUploadRequest(BaseModel):
    path: str


_LOCAL_ALLOWED_SUFFIXES = {".epub", ".pdf"}
_LOCAL_ALLOWED_HOSTS = {"127.0.0.1", "::1", "localhost", "::ffff:127.0.0.1"}


@router.post("/uploads/local")
async def upload_ebook_local(
    body: LocalUploadRequest,
    request: Request,
    background_tasks: BackgroundTasks,
) -> dict:
    """Register a local file path as an upload (desktop app, localhost only).

    Equivalent to POST /api/uploads but takes a file-system path instead of
    multipart data.  Only accepted from loopback addresses so it cannot be
    exploited by remote callers.
    """
    from src.ebook_reader import EbookReader

    import python_app.server as _srv

    # Security: reject non-localhost callers.
    client_host = (request.client.host if request.client else "") or ""
    if client_host not in _LOCAL_ALLOWED_HOSTS:
        raise HTTPException(
            status_code=403, detail="Local uploads are only available from localhost"
        )

    raw = body.path
    src = _resolve_allowed_local_source(raw)
    if not src.exists() or not src.is_file():
        raise HTTPException(status_code=404, detail="File not found")

    if src.suffix.lower() not in _LOCAL_ALLOWED_SUFFIXES:
        raise HTTPException(status_code=400, detail="Only .epub and .pdf files are supported")

    if _srv.MAX_UPLOAD_BYTES and src.stat().st_size > _srv.MAX_UPLOAD_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"File exceeds the {_srv.MAX_UPLOAD_MB} MB limit",
        )

    _srv._cleanup_pending_uploads()
    upload_id = str(uuid.uuid4())
    upload_dir = _srv._resolve_relative_path_within_root(
        _srv.uploads_dir, upload_id, must_exist=False
    )
    upload_dir.mkdir(parents=True, exist_ok=True)

    dest_path = _srv._resolve_relative_path_within_root(upload_dir, src.name, must_exist=False)
    shutil.copy2(src, dest_path)

    file_hash = _sha1_file(src)

    book_title = src.stem
    book_author = "Unknown Author"
    cover_url = None
    cover_mime = None
    cover_filename = None
    cover_path = None

    try:
        reader = EbookReader(str(dest_path))
        if reader.title:
            book_title = reader.title
        if reader.author:
            book_author = reader.author
        cover_blob = reader.extract_cover_image()
        if cover_blob:
            cover_filename = f"cover{cover_blob.extension}"
            cover_path = _srv._resolve_relative_path_within_root(
                upload_dir, cover_filename, must_exist=False
            )
            cover_path.write_bytes(cover_blob.data)
            cover_url = f"/api/uploads/{upload_id}/{cover_filename}"
            cover_mime = cover_blob.media_type
    except Exception:
        pass

    with _srv._pending_lock:
        _srv._pending_uploads[upload_id] = {
            "file_path": str(dest_path),
            "file_name": src.name,
            "book_title": book_title,
            "book_author": book_author,
            "cover_filename": cover_filename,
            "cover_path": str(cover_path) if cover_path else None,
            "cover_mime": cover_mime,
            "file_hash": file_hash,
            "created_at": time.time(),
        }
        _srv._write_pending_upload_metadata(upload_dir, _srv._pending_uploads[upload_id])

    background_tasks.add_task(_precache_uploaded_book, dest_path, book_title, book_author)

    return {
        "uploadId": upload_id,
        "fileName": src.name,
        "bookTitle": book_title,
        "bookAuthor": book_author,
        "coverUrl": cover_url,
        "coverMimeType": cover_mime,
    }
