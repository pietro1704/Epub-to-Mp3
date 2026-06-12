"""OCR preparation helpers for scanned/image-only PDFs."""

from __future__ import annotations

import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

from .paths import CACHE_DIR
from .utils import FileManager


@dataclass(frozen=True)
class PdfTextProbe:
    """Small text-extraction probe used to decide whether a PDF needs OCR."""

    page_count: int
    text_chars: int
    sampled_pages: int

    @property
    def chars_per_page(self) -> float:
        return self.text_chars / max(self.sampled_pages, 1)


@dataclass(frozen=True)
class OcrResult:
    """Outcome of optional OCR preparation."""

    input_path: Path
    output_path: Path
    used_ocr: bool
    needed_ocr: bool
    reason: Optional[str] = None


def probe_pdf_text(path: Path, *, max_pages: int = 20) -> PdfTextProbe:
    """Count extractable PDF text without shelling out to external tools."""

    try:
        from pypdf import PdfReader

        reader = PdfReader(str(path))
        page_count = len(reader.pages)
        sampled = min(page_count, max_pages)
        text_chars = 0
        for page in reader.pages[:sampled]:
            try:
                text_chars += len((page.extract_text() or "").strip())
            except Exception:
                continue
        return PdfTextProbe(page_count=page_count, text_chars=text_chars, sampled_pages=sampled)
    except Exception:
        return PdfTextProbe(page_count=0, text_chars=0, sampled_pages=0)


def pdf_needs_ocr(
    path: Path,
    *,
    min_total_chars: int = 500,
    min_chars_per_page: int = 20,
    probe: Optional[PdfTextProbe] = None,
) -> bool:
    """Return True when a PDF appears image-only/scanned and needs OCR."""

    if Path(path).suffix.lower() != ".pdf":
        return False
    probe = probe or probe_pdf_text(path)
    if probe.page_count <= 0:
        return False
    if probe.page_count <= 3:
        return probe.text_chars < 80
    return probe.text_chars < min_total_chars or probe.chars_per_page < min_chars_per_page


def ocr_runtime_available() -> tuple[bool, Optional[str]]:
    """Check native and Python OCR commands required by the pipeline."""

    if not shutil.which("tesseract"):
        return False, "tesseract not found"
    if _ocrmypdf_command() is None:
        return False, "ocrmypdf not found"
    try:
        result = subprocess.run(
            ["tesseract", "--list-langs"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
            timeout=20,
        )
        langs = {line.strip() for line in (result.stdout or "").splitlines()}
        if "por" not in langs:
            return False, "Portuguese OCR language data (por) not found"
    except Exception as exc:
        return False, f"could not inspect tesseract languages: {exc}"
    return True, None


def _ocrmypdf_command() -> Optional[list[str]]:
    """Return an executable ocrmypdf command, including venv module installs."""

    if shutil.which("ocrmypdf"):
        return ["ocrmypdf"]
    try:
        result = subprocess.run(
            [sys.executable, "-m", "ocrmypdf", "--version"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=20,
        )
        if result.returncode == 0:
            return [sys.executable, "-m", "ocrmypdf"]
    except Exception:
        return None
    return None


def ocr_output_path(input_path: Path, *, cache_root: Path = CACHE_DIR, language: str = "por") -> Path:
    safe_stem = FileManager.sanitize_filename(Path(input_path).stem, max_length=96)
    return Path(cache_root) / "ocr" / f"{safe_stem}-{language}-ocr.pdf"


def prepare_pdf_with_ocr(
    input_path: Path,
    *,
    cache_root: Path = CACHE_DIR,
    language: str = "por",
    force: bool = False,
    log: Optional[Callable[[str], None]] = None,
) -> OcrResult:
    """Return an OCR-ready PDF path, running OCR automatically when needed.

    The original file is returned unchanged when it already has enough text or
    when the OCR runtime is unavailable. Callers can inspect ``needed_ocr`` and
    ``reason`` to decide whether to stop with an actionable diagnostic.
    """

    input_path = Path(input_path)
    if input_path.suffix.lower() != ".pdf":
        return OcrResult(input_path, input_path, used_ocr=False, needed_ocr=False)

    probe = probe_pdf_text(input_path)
    needed = pdf_needs_ocr(input_path, probe=probe)
    if not needed:
        return OcrResult(input_path, input_path, used_ocr=False, needed_ocr=False)

    available, reason = ocr_runtime_available()
    if not available:
        return OcrResult(input_path, input_path, used_ocr=False, needed_ocr=True, reason=reason)

    output_path = ocr_output_path(input_path, cache_root=cache_root, language=language)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    if output_path.exists() and not force:
        ocr_probe = probe_pdf_text(output_path)
        if not pdf_needs_ocr(output_path, probe=ocr_probe):
            return OcrResult(input_path, output_path, used_ocr=True, needed_ocr=True)

    if log:
        log(
            "🔎 PDF parece escaneado/sem texto. Rodando OCR "
            f"({language}) antes da conversão: {output_path}"
        )

    ocrmypdf = _ocrmypdf_command()
    if ocrmypdf is None:
        return OcrResult(
            input_path, input_path, used_ocr=False, needed_ocr=True, reason="ocrmypdf not found"
        )

    cmd = [
        *ocrmypdf,
        "-l",
        language,
        "--deskew",
        "--rotate-pages",
        "--skip-text",
        "--optimize",
        "1",
        str(input_path),
        str(output_path),
    ]
    result = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
    if result.returncode != 0:
        output_path.unlink(missing_ok=True)
        return OcrResult(
            input_path,
            input_path,
            used_ocr=False,
            needed_ocr=True,
            reason=(result.stdout or "ocrmypdf failed").strip()[-1000:],
        )

    return OcrResult(input_path, output_path, used_ocr=True, needed_ocr=True)


__all__ = [
    "OcrResult",
    "PdfTextProbe",
    "ocr_output_path",
    "ocr_runtime_available",
    "pdf_needs_ocr",
    "prepare_pdf_with_ocr",
    "probe_pdf_text",
]
