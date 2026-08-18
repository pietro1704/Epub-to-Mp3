"""OCR fallback for image-only PDF pages."""

from __future__ import annotations

import hashlib
import json
import platform
import shutil
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence


class PdfScanOcrError(RuntimeError):
    """Raised when a scanned PDF cannot provide readable text."""


class PdfScanOcrUnavailableError(PdfScanOcrError):
    """Raised when the current platform has no supported OCR backend."""


@dataclass(frozen=True, slots=True)
class PdfOcrPage:
    """Text recovered from one logical page within a source PDF page."""

    source_page_index: int
    part_index: int
    text: str


class PdfScanOcr:
    """Extract image-only PDF text with the platform's fastest local OCR engine."""

    _helper_timeout_floor_seconds = 90
    _helper_timeout_per_page_seconds = 60
    _worker_count = 4

    def extract(self, pdf_path: Path, page_indices: Sequence[int]) -> list[PdfOcrPage]:
        """Extract requested 1-based PDF pages in their logical reading order."""
        pages = sorted({int(index) for index in page_indices if int(index) > 0})
        if not pages:
            return []
        if platform.system() != "Darwin":
            raise PdfScanOcrUnavailableError(
                "Scanned PDF OCR requires a supported local OCR backend"
            )
        return self._extract_with_macos_vision(pdf_path, pages)

    def _extract_with_macos_vision(
        self, pdf_path: Path, page_indices: list[int]
    ) -> list[PdfOcrPage]:
        helper = self._vision_helper_binary()
        orientation = self._detect_vision_orientation(helper, pdf_path, page_indices)
        with ThreadPoolExecutor(max_workers=min(self._worker_count, len(page_indices))) as executor:
            futures = {
                executor.submit(
                    self._run_vision_helper, helper, pdf_path, [page_index], orientation
                ): page_index
                for page_index in page_indices
            }
            batches: list[list[PdfOcrPage]] = []
            for completed_count, future in enumerate(as_completed(futures), start=1):
                batches.append(future.result())
                print(
                    f"\r📄 OCR scanned pages: {completed_count}/{len(page_indices)}",
                    end="",
                    flush=True,
                )
        print()
        recovered = [page for batch in batches for page in batch]
        return sorted(recovered, key=lambda page: (page.source_page_index, page.part_index))

    def _run_vision_helper(
        self, helper: Path, pdf_path: Path, page_indices: list[int], orientation: int
    ) -> list[PdfOcrPage]:
        timeout = max(
            self._helper_timeout_floor_seconds,
            len(page_indices) * self._helper_timeout_per_page_seconds,
        )
        try:
            completed = subprocess.run(
                [
                    str(helper),
                    f"--orientation={orientation}",
                    str(pdf_path),
                    *(str(index) for index in page_indices),
                ],
                check=False,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise PdfScanOcrError(f"macOS Vision OCR could not run: {exc}") from exc

        if completed.returncode != 0:
            detail = completed.stderr.strip() or completed.stdout.strip() or "unknown error"
            raise PdfScanOcrError(f"macOS Vision OCR failed: {detail}")

        recovered: list[PdfOcrPage] = []
        requested_pages = set(page_indices)
        for line in completed.stdout.splitlines():
            if not line.strip():
                continue
            try:
                payload = json.loads(line)
                source_page_index = int(payload["source_page_index"])
                part_index = int(payload["part_index"])
                text = str(payload["text"]).strip()
            except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
                raise PdfScanOcrError(f"macOS Vision OCR returned invalid output: {exc}") from exc
            if source_page_index not in requested_pages or part_index < 1 or not text:
                continue
            recovered.append(
                PdfOcrPage(
                    source_page_index=source_page_index,
                    part_index=part_index,
                    text=text,
                )
            )
        return recovered

    def _detect_vision_orientation(
        self, helper: Path, pdf_path: Path, page_indices: list[int]
    ) -> int:
        sample_positions = [0, len(page_indices) // 3, (len(page_indices) * 2) // 3, -1]
        sample_pages = sorted({page_indices[position] for position in sample_positions})
        try:
            completed = subprocess.run(
                [
                    str(helper),
                    "--detect-orientation",
                    str(pdf_path),
                    *(str(index) for index in sample_pages),
                ],
                check=False,
                capture_output=True,
                text=True,
                timeout=self._helper_timeout_floor_seconds,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise PdfScanOcrError(f"macOS Vision orientation detection failed: {exc}") from exc
        if completed.returncode != 0:
            detail = completed.stderr.strip() or completed.stdout.strip() or "unknown error"
            raise PdfScanOcrError(f"macOS Vision orientation detection failed: {detail}")
        try:
            orientation = int(completed.stdout.strip())
        except ValueError as exc:
            raise PdfScanOcrError("macOS Vision OCR returned an invalid orientation") from exc
        if orientation not in {1, 3, 6, 8}:
            raise PdfScanOcrError("macOS Vision OCR returned an unsupported orientation")
        return orientation

    def _vision_helper_binary(self) -> Path:
        source = Path(__file__).with_name("pdf_vision_ocr.swift")
        if not source.is_file():
            raise PdfScanOcrUnavailableError("macOS Vision OCR helper is missing")
        swiftc = shutil.which("swiftc")
        if not swiftc:
            raise PdfScanOcrUnavailableError("swiftc is required for macOS Vision OCR")

        fingerprint = hashlib.sha256(source.read_bytes()).hexdigest()[:16]
        cache_dir = Path(tempfile.gettempdir()) / "epub-to-mp3-pdf-vision-ocr"
        cache_dir.mkdir(parents=True, exist_ok=True)
        binary = cache_dir / f"vision-ocr-{fingerprint}"
        if binary.is_file() and binary.stat().st_size > 0:
            return binary

        temporary_binary = cache_dir / f"vision-ocr-{fingerprint}-{hash(source)}.tmp"
        try:
            completed = subprocess.run(
                [swiftc, "-O", str(source), "-o", str(temporary_binary)],
                check=False,
                capture_output=True,
                text=True,
                timeout=120,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise PdfScanOcrUnavailableError(
                f"macOS Vision OCR helper could not compile: {exc}"
            ) from exc
        if completed.returncode != 0:
            detail = completed.stderr.strip() or completed.stdout.strip() or "unknown error"
            raise PdfScanOcrUnavailableError(f"macOS Vision OCR helper could not compile: {detail}")
        temporary_binary.replace(binary)
        return binary
