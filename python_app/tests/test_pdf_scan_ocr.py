"""Tests for the local scanned-PDF OCR adapter."""

from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import pytest
from src.pdf_scan_ocr import (
    PdfOcrPage,
    PdfScanOcr,
    PdfScanOcrError,
    PdfScanOcrUnavailableError,
)


def test_extract_skips_empty_page_requests() -> None:
    assert PdfScanOcr().extract(Path("unused.pdf"), []) == []


@patch("src.pdf_scan_ocr.platform.system", return_value="Linux")
def test_extract_reports_when_the_platform_has_no_ocr_backend(_system: object) -> None:
    with pytest.raises(PdfScanOcrUnavailableError, match="supported local OCR backend"):
        PdfScanOcr().extract(Path("scan.pdf"), [1])


@patch("src.pdf_scan_ocr.subprocess.run")
def test_vision_helper_reads_only_requested_nonempty_records(mock_run: object) -> None:
    stdout = "\n".join(
        [
            json.dumps({"source_page_index": 1, "part_index": 2, "text": "Right page"}),
            json.dumps({"source_page_index": 1, "part_index": 1, "text": "Left page"}),
            json.dumps({"source_page_index": 2, "part_index": 1, "text": "Unexpected page"}),
            json.dumps({"source_page_index": 1, "part_index": 3, "text": ""}),
        ]
    )
    mock_run.return_value = SimpleNamespace(returncode=0, stdout=stdout, stderr="")

    pages = PdfScanOcr()._run_vision_helper(Path("vision-ocr"), Path("scan.pdf"), [1], 6)

    assert pages == [
        PdfOcrPage(source_page_index=1, part_index=2, text="Right page"),
        PdfOcrPage(source_page_index=1, part_index=1, text="Left page"),
    ]


def test_vision_extraction_orders_completed_page_batches() -> None:
    ocr = PdfScanOcr()

    def recovered_page(
        _helper: Path, _path: Path, page_indices: list[int], _orientation: int
    ) -> list[PdfOcrPage]:
        page = page_indices[0]
        return [PdfOcrPage(source_page_index=page, part_index=1, text=f"Page {page}")]

    with (
        patch.object(ocr, "_vision_helper_binary", return_value=Path("vision-ocr")),
        patch.object(ocr, "_detect_vision_orientation", return_value=6),
        patch.object(ocr, "_run_vision_helper", side_effect=recovered_page),
    ):
        pages = ocr._extract_with_macos_vision(Path("scan.pdf"), [3, 1, 2])

    assert pages == [
        PdfOcrPage(source_page_index=1, part_index=1, text="Page 1"),
        PdfOcrPage(source_page_index=2, part_index=1, text="Page 2"),
        PdfOcrPage(source_page_index=3, part_index=1, text="Page 3"),
    ]


@patch("src.pdf_scan_ocr.subprocess.run")
def test_orientation_detection_rejects_an_invalid_helper_value(mock_run: object) -> None:
    mock_run.return_value = SimpleNamespace(returncode=0, stdout="99\n", stderr="")

    with pytest.raises(PdfScanOcrError, match="unsupported orientation"):
        PdfScanOcr()._detect_vision_orientation(Path("vision-ocr"), Path("scan.pdf"), [1])
