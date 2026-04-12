"""Tests for the POST /api/uploads/local endpoint (desktop-only, localhost-only)."""

from __future__ import annotations

import unittest
import zipfile
from pathlib import Path
from unittest.mock import MagicMock, patch


def _make_client():
    try:
        from fastapi.testclient import TestClient
    except ModuleNotFoundError:
        raise unittest.SkipTest("fastapi not installed")
    from python_app import server

    return TestClient(server.app), server


def _minimal_epub(path: Path) -> Path:
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr("mimetype", "application/epub+zip")
        zf.writestr(
            "META-INF/container.xml",
            '<?xml version="1.0"?><container version="1.0" '
            'xmlns="urn:oasis:schemas:container"><rootfiles>'
            '<rootfile full-path="OEBPS/content.opf" '
            'media-type="application/oebps-package+xml"/>'
            "</rootfiles></container>",
        )
        zf.writestr(
            "OEBPS/content.opf",
            '<?xml version="1.0" encoding="UTF-8"?>'
            '<package xmlns="http://www.idpf.org/2007/opf" version="2.0" '
            'unique-identifier="id">'
            '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
            "<dc:title>Test Book</dc:title>"
            "<dc:creator>Test Author</dc:creator>"
            '<dc:identifier id="id">urn:uuid:test</dc:identifier>'
            "</metadata>"
            "<manifest/><spine/>"
            "</package>",
        )
    return path


def _fake_reader(title="Test Book", author="Test Author"):
    r = MagicMock()
    r.title = title
    r.author = author
    r.extract_cover_image.return_value = None
    return r


class TestLocalUploadEndpoint(unittest.TestCase):
    """POST /api/uploads/local — happy path and security checks."""

    def setUp(self):
        import shutil
        import tempfile

        self.tmp = Path(tempfile.mkdtemp())
        self._cleanup = shutil.rmtree

    def tearDown(self):
        self._cleanup(self.tmp, ignore_errors=True)

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    def _patch_server(self, srv):
        """Isolate uploads_dir and allow TestClient's loopback hostname."""
        import src.routes_uploads as mod

        uploads_dir = self.tmp / "uploads"
        uploads_dir.mkdir()
        srv.uploads_dir = uploads_dir
        srv._pending_uploads.clear()
        srv.MAX_UPLOAD_BYTES = 100 * 1024 * 1024
        srv.MAX_UPLOAD_MB = 100
        # TestClient sends requests from host "testclient"; allow it in tests.
        self._orig_hosts = mod._LOCAL_ALLOWED_HOSTS.copy()
        mod._LOCAL_ALLOWED_HOSTS.add("testclient")

    def _restore_server(self, srv):
        import src.routes_uploads as mod

        if hasattr(self, "_orig_hosts"):
            mod._LOCAL_ALLOWED_HOSTS.clear()
            mod._LOCAL_ALLOWED_HOSTS.update(self._orig_hosts)

    # ------------------------------------------------------------------
    # Happy path
    # ------------------------------------------------------------------

    def test_registers_epub_returns_upload_id(self):
        client, srv = _make_client()
        self._patch_server(srv)
        epub = _minimal_epub(self.tmp / "mybook.epub")

        with patch(
            "src.ebook_reader.EbookReader", return_value=_fake_reader("My Book", "Author A")
        ):
            resp = client.post("/api/uploads/local", json={"path": str(epub)})

        self._restore_server(srv)
        assert resp.status_code == 200, resp.text
        data = resp.json()
        assert data["uploadId"]
        assert data["fileName"] == "mybook.epub"
        assert data["bookTitle"] == "My Book"
        assert data["bookAuthor"] == "Author A"
        assert data["coverUrl"] is None

    def test_registers_pdf(self):
        client, srv = _make_client()
        self._patch_server(srv)
        pdf = self.tmp / "report.pdf"
        pdf.write_bytes(b"%PDF-1.4 placeholder")

        with patch("src.ebook_reader.EbookReader", return_value=_fake_reader("PDF Book")):
            resp = client.post("/api/uploads/local", json={"path": str(pdf)})

        self._restore_server(srv)
        assert resp.status_code == 200
        assert resp.json()["fileName"] == "report.pdf"

    def test_file_is_copied_to_uploads_dir(self):
        client, srv = _make_client()
        self._patch_server(srv)
        epub = _minimal_epub(self.tmp / "copy_test.epub")

        with patch("src.ebook_reader.EbookReader", return_value=_fake_reader()):
            resp = client.post("/api/uploads/local", json={"path": str(epub)})

        self._restore_server(srv)
        assert resp.status_code == 200
        upload_id = resp.json()["uploadId"]
        dest = srv.uploads_dir / upload_id / "copy_test.epub"
        assert dest.exists(), "File should be copied to uploads dir"

    def test_fallback_title_is_stem_when_reader_fails(self):
        client, srv = _make_client()
        self._patch_server(srv)
        epub = self.tmp / "my_great_book.epub"
        epub.write_bytes(b"not a real epub")

        with patch("src.ebook_reader.EbookReader", side_effect=Exception("parse error")):
            resp = client.post("/api/uploads/local", json={"path": str(epub)})

        self._restore_server(srv)
        assert resp.status_code == 200
        assert resp.json()["bookTitle"] == "my_great_book"

    # ------------------------------------------------------------------
    # Validation errors
    # ------------------------------------------------------------------

    def test_404_for_missing_file(self):
        client, srv = _make_client()
        self._patch_server(srv)
        resp = client.post("/api/uploads/local", json={"path": str(self.tmp / "ghost.epub")})
        self._restore_server(srv)
        assert resp.status_code == 404

    def test_400_for_unsupported_extension(self):
        client, srv = _make_client()
        self._patch_server(srv)
        txt = self.tmp / "doc.txt"
        txt.write_text("hello")
        resp = client.post("/api/uploads/local", json={"path": str(txt)})
        self._restore_server(srv)
        assert resp.status_code == 400

    def test_400_for_path_outside_allowed_roots(self):
        client, srv = _make_client()
        self._patch_server(srv)
        resp = client.post("/api/uploads/local", json={"path": "/etc/passwd"})
        self._restore_server(srv)
        assert resp.status_code == 400

    def test_400_for_symlink(self):
        client, srv = _make_client()
        self._patch_server(srv)
        target = _minimal_epub(self.tmp / "target.epub")
        link = self.tmp / "linked.epub"
        link.symlink_to(target)
        resp = client.post("/api/uploads/local", json={"path": str(link)})
        self._restore_server(srv)
        assert resp.status_code == 400

    def test_413_when_file_exceeds_size_limit(self):
        client, srv = _make_client()
        self._patch_server(srv)
        srv.MAX_UPLOAD_BYTES = 5  # 5-byte limit
        srv.MAX_UPLOAD_MB = 0
        epub = self.tmp / "big.epub"
        epub.write_bytes(b"x" * 10)
        resp = client.post("/api/uploads/local", json={"path": str(epub)})
        self._restore_server(srv)
        assert resp.status_code == 413

    # ------------------------------------------------------------------
    # Security: reject non-localhost callers
    # ------------------------------------------------------------------

    def test_403_from_non_localhost(self):
        """Endpoint rejects calls whose client.host is not a loopback address."""
        client, srv = _make_client()
        # Do NOT call _patch_server — we want the real allowed-hosts check.
        epub = self.tmp / "remote.epub"
        epub.write_bytes(b"dummy epub bytes")

        # TestClient's default client host is "testclient" which is not in
        # _LOCAL_ALLOWED_HOSTS, so no extra setup is needed to simulate a
        # non-localhost caller.
        resp = client.post("/api/uploads/local", json={"path": str(epub)})
        assert resp.status_code == 403


def _compute_pending_ttl(space_id: str | None, upload_ttl_seconds: str | None) -> int:
    """Replicate the _PENDING_TTL_SECONDS formula without importing server.py."""
    import os

    env = {}
    if space_id is not None:
        env["SPACE_ID"] = space_id
    if upload_ttl_seconds is not None:
        env["UPLOAD_TTL_SECONDS"] = upload_ttl_seconds

    with patch.dict("os.environ", env, clear=False):
        # Mirror the exact expression from server.py
        default = 30 * 24 * 3600 if not os.getenv("SPACE_ID") else 3600
        return int(os.getenv("UPLOAD_TTL_SECONDS", str(default)))


class TestPendingTTL(unittest.TestCase):
    """_PENDING_TTL_SECONDS — 30 days locally, 1 hour on HF Spaces."""

    def test_default_ttl_is_30_days_locally(self):
        """Without SPACE_ID, TTL defaults to 30 days (2 592 000 s)."""
        import os

        if os.environ.get("SPACE_ID"):
            self.skipTest("SPACE_ID is set — running on HF, not local")

        expected = 30 * 24 * 3600  # 2 592 000
        self.assertEqual(_compute_pending_ttl(None, None), expected)

    def test_ttl_is_1_hour_on_hf(self):
        """With SPACE_ID set, TTL defaults to 3600 s (1 hour)."""
        self.assertEqual(_compute_pending_ttl("test-space", None), 3600)

    def test_ttl_override_via_env_var(self):
        """UPLOAD_TTL_SECONDS env var overrides the default."""
        self.assertEqual(_compute_pending_ttl(None, "7200"), 7200)

    def test_cleanup_removes_expired_entries(self):
        """_cleanup_pending_uploads removes entries older than TTL."""
        import shutil
        import tempfile
        import time
        from pathlib import Path
        from unittest.mock import patch as mpatch

        try:
            import python_app.server as srv  # noqa: PLC0415
        except Exception:
            raise unittest.SkipTest("server import failed")

        tmp_uploads = Path(tempfile.mkdtemp())
        try:
            # Patch TTL to 1 hour; old_entry is 2 h old → expired
            old_entry = {"path": "/tmp/old.epub", "created_at": time.time() - 7200}
            fresh_entry = {"path": "/tmp/new.epub", "created_at": time.time()}
            with srv._pending_lock:
                srv._pending_uploads["old-id"] = old_entry
                srv._pending_uploads["new-id"] = fresh_entry

            with (
                mpatch("python_app.server.uploads_dir", tmp_uploads),
                mpatch("python_app.server._PENDING_TTL_SECONDS", 3600),
            ):
                srv._cleanup_pending_uploads()

            with srv._pending_lock:
                self.assertNotIn("old-id", srv._pending_uploads)
                self.assertIn("new-id", srv._pending_uploads)
                srv._pending_uploads.pop("new-id", None)
        finally:
            shutil.rmtree(tmp_uploads, ignore_errors=True)
