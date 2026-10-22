"""Estimate endpoint regression scenarios, collected by test_server_conversion."""

from __future__ import annotations

from python_app.tests._server_conversion_test_support import Path as Path
from python_app.tests._server_conversion_test_support import TestClient as TestClient
from python_app.tests._server_conversion_test_support import _make_telemetry as _make_telemetry
from python_app.tests._server_conversion_test_support import server as server


# ---------------------------------------------------------------------------
# GET /api/estimate
# ---------------------------------------------------------------------------


class TestEstimateEndpoint:
    def _make_client(self) -> "TestClient":
        from fastapi.testclient import TestClient

        return TestClient(server.app)

    def _register_upload(self, monkeypatch, tmp_path, chapters: list[dict]) -> tuple[str, Path]:
        """Register a fake upload and return (upload_id, epub_path)."""
        import uuid as _uuid

        upload_id = str(_uuid.uuid4())
        upload_dir = tmp_path / upload_id
        upload_dir.mkdir()
        # Create a dummy epub file (content doesn't matter; we bypass EbookReader)
        epub_path = upload_dir / "book.epub"
        epub_path.write_bytes(b"fake")

        # Patch _pending_uploads so the endpoint finds the file
        monkeypatch.setitem(
            server._pending_uploads,
            upload_id,
            {
                "file_path": str(epub_path),
                "file_name": "book.epub",
                "book_title": "Test Book",
            },
        )

        # Patch get_cache_manager to return cached chapter data
        cached_data = {
            "title": "Test Book",
            "author": "Test Author",
            "chapters": chapters,
            "size": 4,
            "mtime": epub_path.stat().st_mtime,
        }

        class _FakeCache:
            def get_cached_chapters(self, path):
                return cached_data

        monkeypatch.setattr(server, "get_cache_manager", lambda: _FakeCache())

        return upload_id, epub_path

    def test_returns_estimate_with_cache_hit(self, monkeypatch, tmp_path):
        chapters = [
            {"title": "Chapter 1", "text": "a" * 5000},
            {"title": "Chapter 2", "text": "b" * 7000},
        ]
        upload_id, _ = self._register_upload(monkeypatch, tmp_path, chapters)

        monkeypatch.setattr(server, "uploads_dir", tmp_path)
        client = self._make_client()
        resp = client.get(f"/api/estimate?upload_id={upload_id}")
        assert resp.status_code == 200
        data = resp.json()
        assert data["chapters"] == 2
        assert data["total_chars"] == 12000
        assert "estimated_duration_seconds" in data
        assert data["estimated_duration_seconds"] > 0
        assert "estimated_output_mb" in data
        assert "engine_estimates" in data
        assert "edge" in data["engine_estimates"]
        assert "piper" in data["engine_estimates"]
        assert "chapter_breakdown" in data
        assert len(data["chapter_breakdown"]) == 2

    def test_returns_404_for_unknown_upload_id(self, monkeypatch, tmp_path):
        monkeypatch.setattr(server, "uploads_dir", tmp_path)
        client = self._make_client()
        resp = client.get("/api/estimate?upload_id=nonexistent-id")
        assert resp.status_code == 404

    def test_engine_param_selects_engine(self, monkeypatch, tmp_path):
        chapters = [{"title": "Ch", "text": "x" * 10000}]
        upload_id, _ = self._register_upload(monkeypatch, tmp_path, chapters)
        monkeypatch.setattr(server, "uploads_dir", tmp_path)
        _make_telemetry(tmp_path, monkeypatch)  # isolate from real telemetry on disk
        client = self._make_client()

        resp_edge = client.get(f"/api/estimate?upload_id={upload_id}&engine=edge")
        resp_piper = client.get(f"/api/estimate?upload_id={upload_id}&engine=piper")
        assert resp_edge.status_code == 200
        assert resp_piper.status_code == 200
        # Piper is slower → longer estimate
        assert (
            resp_piper.json()["estimated_duration_seconds"]
            > resp_edge.json()["estimated_duration_seconds"]
        )

    def test_telemetry_based_flag_false_with_no_samples(self, monkeypatch, tmp_path):
        chapters = [{"title": "Ch", "text": "x" * 5000}]
        upload_id, _ = self._register_upload(monkeypatch, tmp_path, chapters)
        monkeypatch.setattr(server, "uploads_dir", tmp_path)

        # Empty telemetry
        from src.telemetry import TelemetryRecorder

        empty_telemetry = TelemetryRecorder(telemetry_file=tmp_path / "empty.json")
        monkeypatch.setattr(server, "telemetry", empty_telemetry)

        client = self._make_client()
        resp = client.get(f"/api/estimate?upload_id={upload_id}&engine=edge")
        data = resp.json()
        assert data["telemetry_based"] is False
        assert data["chars_per_second"] == 110.0  # default fallback

    def test_duration_formatted_contains_minutes(self, monkeypatch, tmp_path):
        # 12 000 chars at 110 chars/s ≈ 109s ≈ 1m 49s
        chapters = [{"title": "Ch", "text": "x" * 12000}]
        upload_id, _ = self._register_upload(monkeypatch, tmp_path, chapters)
        monkeypatch.setattr(server, "uploads_dir", tmp_path)

        from src.telemetry import TelemetryRecorder

        empty_telemetry = TelemetryRecorder(telemetry_file=tmp_path / "empty2.json")
        monkeypatch.setattr(server, "telemetry", empty_telemetry)

        client = self._make_client()
        resp = client.get(f"/api/estimate?upload_id={upload_id}&engine=edge")
        formatted = resp.json()["estimated_duration_formatted"]
        assert "m" in formatted
