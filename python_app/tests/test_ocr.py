from __future__ import annotations

import subprocess
from pathlib import Path
from unittest.mock import Mock, patch

from src.ocr import (
    OcrResult,
    PdfTextProbe,
    ocr_output_path,
    ocr_runtime_available,
    pdf_needs_ocr,
    prepare_pdf_with_ocr,
)


def test_pdf_needs_ocr_for_large_image_only_pdf(tmp_path: Path):
    pdf = tmp_path / "scan.pdf"
    pdf.write_bytes(b"%PDF-1.4\n")

    assert pdf_needs_ocr(pdf, probe=PdfTextProbe(page_count=638, text_chars=0, sampled_pages=20))


def test_pdf_does_not_need_ocr_when_text_is_extractable(tmp_path: Path):
    pdf = tmp_path / "book.pdf"
    pdf.write_bytes(b"%PDF-1.4\n")

    assert not pdf_needs_ocr(
        pdf, probe=PdfTextProbe(page_count=300, text_chars=10_000, sampled_pages=20)
    )


def test_ocr_output_path_is_cached_and_sanitized(tmp_path: Path):
    source = tmp_path / "Conhecimento por Presença: teste.pdf"
    result = ocr_output_path(source, cache_root=tmp_path / "cache", language="por")

    assert result.parent == tmp_path / "cache" / "ocr"
    assert result.name.endswith("-por-ocr.pdf")
    assert ":" not in result.name


@patch("src.ocr.shutil.which")
@patch("src.ocr.subprocess.run")
def test_ocr_runtime_requires_tesseract_portuguese_data(mock_run: Mock, mock_which: Mock):
    mock_which.side_effect = lambda command: f"/usr/bin/{command}"
    mock_run.return_value = subprocess.CompletedProcess(
        ["tesseract", "--list-langs"], 0, stdout="List of available languages (2):\nosd\npor\n"
    )

    assert ocr_runtime_available() == (True, None)


@patch("src.ocr.ocr_runtime_available", return_value=(False, "tesseract not found"))
@patch("src.ocr.probe_pdf_text", return_value=PdfTextProbe(page_count=20, text_chars=0, sampled_pages=20))
def test_prepare_pdf_reports_needed_ocr_when_runtime_missing(
    mock_probe: Mock, mock_runtime: Mock, tmp_path: Path
):
    source = tmp_path / "scan.pdf"
    source.write_bytes(b"%PDF-1.4\n")

    result = prepare_pdf_with_ocr(source, cache_root=tmp_path / "cache")

    assert result == OcrResult(
        input_path=source,
        output_path=source,
        used_ocr=False,
        needed_ocr=True,
        reason="tesseract not found",
    )


@patch("src.ocr.ocr_runtime_available", return_value=(True, None))
@patch("src.ocr.probe_pdf_text", return_value=PdfTextProbe(page_count=20, text_chars=0, sampled_pages=20))
@patch("src.ocr.subprocess.run")
def test_prepare_pdf_runs_ocrmypdf_when_needed(
    mock_run: Mock, mock_probe: Mock, mock_runtime: Mock, tmp_path: Path
):
    source = tmp_path / "scan.pdf"
    source.write_bytes(b"%PDF-1.4\n")

    def fake_run(command, **kwargs):
        if command[-1] == "--version":
            return subprocess.CompletedProcess(command, 0, stdout="17.6.0")
        output = Path(command[-1])
        output.write_bytes(b"%PDF-1.4 ocr\n")
        return subprocess.CompletedProcess(command, 0, stdout="ok")

    mock_run.side_effect = fake_run

    result = prepare_pdf_with_ocr(source, cache_root=tmp_path / "cache", language="por")

    assert result.used_ocr
    assert result.needed_ocr
    assert result.output_path.exists()
    assert result.output_path.name.endswith("-por-ocr.pdf")
    command = mock_run.call_args.args[0]
    assert "ocrmypdf" in command
    lang_index = command.index("-l")
    assert command[lang_index : lang_index + 4] == ["-l", "por", "--deskew", "--rotate-pages"]


@patch("src.ocr.probe_pdf_text", return_value=PdfTextProbe(page_count=20, text_chars=8000, sampled_pages=20))
def test_prepare_pdf_skips_ocr_when_text_exists(mock_probe: Mock, tmp_path: Path):
    source = tmp_path / "text.pdf"
    source.write_bytes(b"%PDF-1.4\n")

    result = prepare_pdf_with_ocr(source, cache_root=tmp_path / "cache")

    assert result == OcrResult(source, source, used_ocr=False, needed_ocr=False)
