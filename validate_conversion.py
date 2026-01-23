#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Validação completa de uma conversão já concluída (EPUB → MP3) e correção opcional.

Verifica:
1) Texto original (EPUB) vs texto cached (parsed.txt)
2) Texto cached (parsed.txt) vs texto enviado para TTS (pre-tts.txt)
3) Duração estimada do texto vs duração real do MP3
4) Segmentos ou arquivos faltantes/duplicados/cortados

Opcional (--auto-fix):
 - Reprocessa o livro inteiro com cache limpo para corrigir capítulos faltantes ou divergentes.
"""

import asyncio
import hashlib
import re
import sys
import unicodedata
from pathlib import Path
from typing import Dict, List, Tuple

# Add project to path
sys.path.insert(0, str(Path(__file__).parent))

from python_app.src.audio_validator import AudioValidator
from python_app.src.config import ConversionConfig
from python_app.src.converter import AudioConverter
from python_app.src.ebook_reader import EbookReader
from python_app.src.utils import FileManager, resolve_cache_root


def find_cache_dir(book_path: Path) -> Path:
    """Find cache directory for a book."""
    cache_root = Path(".cache")

    # Try to find by book title
    book_name = book_path.stem

    # Search for matching cache directories
    for cache_dir in cache_root.iterdir():
        if cache_dir.is_dir() and book_name.lower() in cache_dir.name.lower():
            # Look for engine subdirectories
            for engine_dir in cache_dir.iterdir():
                if engine_dir.is_dir() and (engine_dir / "text").exists():
                    return engine_dir
            # Try nested structure
            for subdir in cache_dir.rglob("text"):
                if subdir.is_dir():
                    return subdir.parent

    raise FileNotFoundError(f"Cache directory not found for {book_path.name}")


def load_epub_chapters(epub_path: Path) -> List[Tuple[int, str, str]]:
    """Load all chapters from EPUB."""
    print(f"📖 Reading EPUB: {epub_path.name}")
    reader = EbookReader(str(epub_path))
    try:
        from python_app.main import ConverterApplication

        app = ConverterApplication()
        preview_config = app.config.create_conversion_config(
            engine="edge",
            output_dir=str(Path.cwd() / "output"),
            book_title=reader.title,
            preserve_all_chapters=True,
        )
        preview_config.footnote_mode = "inline"
        preview_config.footnote_context_words = app.FOOTNOTE_CONTEXT_WORDS
        structure_items = app._generate_structure_items(reader, filter_chapters=False)
        structure_items = app._apply_text_transforms(structure_items, preview_config, reader)
        app._apply_structure_to_reader(reader, structure_items)
    except Exception as exc:
        print(f"⚠️  Validation fallback: failed to apply structure transforms ({exc})")

    chapters = reader.get_chapter_structure(preserve_all=True)

    result = []
    for i, chapter in enumerate(chapters, 1):
        # Use structured text to match cached parsed content
        text = chapter.text or ""
        result.append((i, chapter.name, text))

    print(f"   ✅ Loaded {len(result)} chapters from EPUB")
    return result


def find_text_files(text_dirs: List[Path], chapter_num: int) -> Dict[str, Path]:
    """Find parsed and pre-tts text files for a chapter by numeric prefix."""
    for text_dir in text_dirs:
        if not text_dir.exists():
            continue
        files: Dict[str, Path] = {}
        for txt_file in text_dir.glob(f"{chapter_num} - *"):
            if txt_file.name.endswith("-parsed.txt"):
                files["parsed"] = txt_file
            elif txt_file.name.endswith("-pre-tts.txt"):
                files["pre_tts"] = txt_file
        if files:
            return files
    return {}


def find_text_files_by_title(text_dirs: List[Path], chapter_title: str) -> Dict[str, Path]:
    """Fallback: find parsed and pre-tts text files by matching chapter title."""
    target = normalize_title_key(chapter_title)
    for text_dir in text_dirs:
        if not text_dir.exists():
            continue
        files: Dict[str, Path] = {}
        for txt_file in text_dir.glob("*.txt"):
            stem = _strip_text_suffix(_strip_numeric_prefix(txt_file.stem))
            name_norm = normalize_title_key(stem)
            if target and target[:40] in name_norm:
                if txt_file.name.endswith("-parsed.txt"):
                    files.setdefault("parsed", txt_file)
                elif txt_file.name.endswith("-pre-tts.txt"):
                    files.setdefault("pre_tts", txt_file)
            if len(files) == 2:
                break
        if files:
            return files
    return {}


def resolve_cache_dir_with_text(cache_dir: Path) -> Path:
    """
    Some cache layouts nest engine names (e.g., edge/edge/text). Walk down one level
    to find a directory that contains 'text'.
    """
    if (cache_dir / "text").exists():
        return cache_dir
    try:
        children = [p for p in cache_dir.iterdir() if p.is_dir()]
    except FileNotFoundError:
        return cache_dir
    for child in children:
        if (child / "text").exists():
            return child
    return cache_dir


def _strip_numeric_prefix(name: str) -> str:
    """Remove leading numeric prefix like '001 - ' or '3.0 - ' from filenames."""
    pattern = re.compile(r"^\d+(?:\.\d+)?[\s._-]+")
    cleaned = name
    while True:
        updated = pattern.sub("", cleaned)
        if updated == cleaned:
            return cleaned
        cleaned = updated


def _strip_text_suffix(name: str) -> str:
    """Remove trailing '-parsed' or '-pre-tts' suffix from text filenames."""
    return re.sub(r"-(parsed|pre-tts)$", "", name, flags=re.IGNORECASE).strip()


def build_cache_index(text_dirs: List[Path]) -> Dict[str, Dict[str, Path]]:
    """
    Build an index of parsed/pre-tts files keyed by normalized title (without numeric prefix).
    Prefer parsed files that have a sibling pre-tts with the same stem.
    """
    index: Dict[str, Dict[str, Path]] = {}
    pre_tts_stems: Dict[str, set[str]] = {}

    for text_dir in text_dirs:
        if not text_dir.exists():
            continue
        for txt_file in text_dir.glob("*.txt"):
            if not txt_file.name.endswith("-pre-tts.txt"):
                continue
            stem = _strip_numeric_prefix(txt_file.stem)
            stem = _strip_text_suffix(stem)
            norm_title = normalize_title_key(stem)
            pre_tts_stems.setdefault(norm_title, set()).add(stem)
            index.setdefault(norm_title, {})["pre_tts"] = txt_file

    for text_dir in text_dirs:
        if not text_dir.exists():
            continue
        for txt_file in text_dir.glob("*.txt"):
            if not txt_file.name.endswith("-parsed.txt"):
                continue
            stem = _strip_numeric_prefix(txt_file.stem)
            stem = _strip_text_suffix(stem)
            norm_title = normalize_title_key(stem)
            index.setdefault(norm_title, {})

            prefers = stem in pre_tts_stems.get(norm_title, set())
            if prefers or "parsed" not in index[norm_title]:
                index[norm_title]["parsed"] = txt_file
    return index


def build_mp3_index(output_dir: Path) -> Dict[str, Path]:
    """Index MP3 files keyed by normalized title (without numeric prefix)."""
    index: Dict[str, Path] = {}
    if not output_dir.exists():
        return index
    for mp3 in output_dir.glob("*.mp3"):
        stem = _strip_numeric_prefix(mp3.stem)
        norm = normalize_title_key(stem)
        index[norm] = mp3
    return index


def find_mp3_by_title(output_dir: Path, chapter_title: str) -> Path | None:
    """Find MP3 file by matching normalized title (ignores numeric prefix)."""
    if not output_dir.exists():
        return None

    target = normalize_title_key(_strip_numeric_prefix(chapter_title))
    best: Path | None = None
    for mp3 in output_dir.glob("*.mp3"):
        name_norm = normalize_title_key(_strip_numeric_prefix(mp3.stem))
        if target and target[:40] in name_norm:
            best = mp3
            break
    return best


def find_mp3_file(output_dir: Path, chapter_num: int) -> Path | None:
    """Find MP3 file for a chapter by numeric prefix (legacy)."""
    if not output_dir.exists():
        return None

    # Try exact match first
    for mp3 in output_dir.glob(f"{chapter_num}.*"):
        if mp3.suffix == ".mp3":
            return mp3

    # Try fuzzy match
    for mp3 in output_dir.glob(f"{chapter_num} - *.mp3"):
        return mp3

    return None


def normalize_text(text: str) -> str:
    """Normalize text for comparison."""
    # Remove extra whitespace
    text = re.sub(r"\s+", " ", text)
    # Remove leading/trailing whitespace
    text = text.strip()
    return text


def normalize_title(text: str) -> str:
    """Normalize a title or filename for matching across cache/output variations."""
    text = normalize_text(text)
    text = text.replace("_", " ")
    text = re.sub(r"[^\w\s]", " ", text, flags=re.UNICODE)
    text = "".join(
        ch for ch in unicodedata.normalize("NFKD", text) if not unicodedata.combining(ch)
    )
    text = re.sub(r"\s+", " ", text).strip().lower()
    return text


def normalize_title_key(text: str, limit: int = 80) -> str:
    """Normalize and shorten titles to improve matching with truncated filenames."""
    normalized = normalize_title(text)
    if limit:
        normalized = normalized[:limit].rstrip()
    return normalized


HTML_TAG_PATTERN = re.compile(r"<[^>]+>")


def contains_html_markup(text: str | None) -> bool:
    """Detect if text still contains HTML tags or markup."""
    if not text:
        return False
    return bool(HTML_TAG_PATTERN.search(text))


def normalized_file_title(path: Path) -> str:
    """Normalize a filename (mp3/txt) to compare with chapter titles."""
    stem = _strip_text_suffix(_strip_numeric_prefix(path.stem))
    return normalize_title_key(stem)


def normalized_leading_text(text: str, limit: int = 120) -> str:
    """Normalize the leading portion of chapter text to validate filename alignment."""
    cleaned = HTML_TAG_PATTERN.sub(" ", text or "")
    cleaned = normalize_text(cleaned)
    if not cleaned:
        return ""
    return normalize_title_key(cleaned[:limit])


def titles_align(expected: str, candidate: str) -> bool:
    """Check if two normalized title fragments refer to the same chapter."""
    if not expected or not candidate:
        return False
    return (
        expected.startswith(candidate)
        or candidate.startswith(expected)
        or expected in candidate
        or candidate in expected
    )


def _sample_edges(text: str, size: int = 180) -> Tuple[str, str]:
    """Return normalized start/end samples for integrity checks."""
    normalized = normalize_text(text)
    if len(normalized) <= size * 2:
        return normalized, normalized
    return normalized[:size], normalized[-size:]


def strip_formatting_cues(text: str) -> str:
    """Remove audible formatting cue phrases from pre-TTS text."""
    if not text:
        return ""
    try:
        from python_app.src.text_formatting import TextFormattingProcessor

        phrases: set[str] = set()
        for locale_map in TextFormattingProcessor.CUE_LABELS.values():
            for start, end in locale_map.values():
                phrases.add(start)
                phrases.add(end)
        phrases.update(TextFormattingProcessor.FOOTNOTE_END_PHRASES)
    except Exception:
        return text

    cleaned = text
    for phrase in sorted(phrases, key=len, reverse=True):
        cleaned = re.sub(re.escape(phrase), "", cleaned, flags=re.IGNORECASE)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    return cleaned


def hash_text(text: str) -> str:
    """Return stable hash for duplicate detection."""
    return hashlib.md5(normalize_text(text).encode("utf-8")).hexdigest()


def hash_file(path: Path) -> str:
    """Return stable hash for audio duplication detection."""
    hasher = hashlib.sha1()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def detect_duplicate_audio_files(output_dir: Path, min_size_bytes: int = 1024) -> List[List[Path]]:
    """Detect duplicated audio files by hashing MP3 payloads."""
    groups: Dict[str, List[Path]] = {}
    for mp3 in sorted(output_dir.glob("*.mp3")):
        try:
            if mp3.stat().st_size < min_size_bytes:
                continue
        except OSError:
            continue
        groups.setdefault(hash_file(mp3), []).append(mp3)
    return [paths for paths in groups.values() if len(paths) > 1]


def compare_texts(original: str, cached: str) -> Tuple[bool, int, str]:
    """
    Compare two texts and return (is_equal, diff_chars, description).
    """
    norm_orig = normalize_text(original)
    norm_cached = normalize_text(cached)

    if norm_orig == norm_cached:
        return True, 0, "Identical"

    diff_chars = len(norm_orig) - len(norm_cached)

    if diff_chars == 0:
        return False, diff_chars, "Content differs (same length)"

    # Find what's different
    if len(norm_cached) < len(norm_orig):
        # Text was removed
        return False, diff_chars, f"Missing {diff_chars} chars from cached (truncation)"
    else:
        # Text was added
        return False, diff_chars, f"Added {-diff_chars} chars to cached"


def validate_book(epub_path: Path, output_dir: Path | None = None, cache_dir: Path | None = None):
    """
    Validate complete book conversion.
    """
    print("\n" + "=" * 70)
    print("🔍 VALIDAÇÃO COMPLETA DE CONVERSÃO EPUB → MP3")
    print("=" * 70 + "\n")

    # Find cache directory
    if cache_dir is None:
        try:
            cache_dir = find_cache_dir(epub_path)
            print(f"📁 Cache directory: {cache_dir}")
        except FileNotFoundError as e:
            print(f"❌ ERROR: {e}")
            return
    else:
        print(f"📁 Cache directory (provided): {cache_dir}")

    cache_dir = resolve_cache_dir_with_text(cache_dir)

    # Find output directory
    if output_dir is None:
        # Try to find output directory
        output_base = Path("output")
        for out_dir in output_base.rglob("*"):
            if out_dir.is_dir() and any(mp3.suffix == ".mp3" for mp3 in out_dir.glob("*")):
                output_dir = out_dir
                break

        if output_dir is None:
            print("❌ ERROR: Output directory not found")
            return

    print(f"📁 Output directory: {output_dir}\n")

    output_text_dir = output_dir / "text" if output_dir else None
    text_dirs = [
        path for path in (output_text_dir, cache_dir / "text") if path is not None and path.exists()
    ]
    cache_index = build_cache_index(text_dirs)
    mp3_index = build_mp3_index(output_dir)

    # Load EPUB chapters
    epub_chapters = load_epub_chapters(epub_path)

    # Validation statistics
    stats = {
        "total_chapters": len([c for c in epub_chapters if normalize_text(c[2])]),
        "missing_cache": 0,
        "text_mismatch": 0,
        "parsed_pretts_diff": 0,
        "missing_mp3": 0,
        "duration_mismatch": 0,
        "audio_duplicate": 0,
        "perfect": 0,
    }

    issues = []
    validator = AudioValidator()
    text_hashes: Dict[str, List[int]] = {}
    chapter_text_hash: Dict[int, str] = {}
    audio_hashes: Dict[str, Dict[str, object]] = {}

    print(f"{'Ch':<4} {'Status':<12} {'EPUB':<8} {'Parsed':<8} {'PreTTS':<8} {'MP3':<8} {'Issue'}")
    print("-" * 70)

    for chapter_num, chapter_title, epub_text in epub_chapters:
        # Skip empty chapters (e.g., cover/blank pages) to align with cached numbering
        if not epub_text or not normalize_text(epub_text):
            continue
        status = "✅"
        issue_desc = ""
        norm_title = normalize_title_key(_strip_numeric_prefix(chapter_title))
        leading_title = normalized_leading_text(epub_text)
        expected_titles = [t for t in (norm_title, leading_title) if t]

        if contains_html_markup(chapter_title):
            stats["text_mismatch"] += 1
            status = "❌"
            issue_desc = "HTML in title"
            issues.append(
                f"Chapter {chapter_num}: Chapter title contains HTML/markup: {chapter_title}"
            )

        # Find cached text files (prefer title-based mapping to avoid index mismatch)
        text_files = cache_index.get(norm_title, {})
        if not text_files:
            text_files = find_text_files_by_title(text_dirs, chapter_title)
        if not text_files and text_dirs:
            text_files = find_text_files(text_dirs, chapter_num)

        if not text_files:
            stats["missing_cache"] += 1
            status = "⚠️ "
            issue_desc = "No cache files"
            issues.append(f"Chapter {chapter_num}: Missing cache files")
        else:
            # Validate filenames align with EPUB titles/heading text
            for label, path in text_files.items():
                file_norm = normalized_file_title(path)
                if expected_titles and not any(titles_align(t, file_norm) for t in expected_titles):
                    stats["text_mismatch"] += 1
                    status = "❌"
                    issue_desc = (issue_desc + " Filename mismatch").strip()
                    issues.append(
                        f"Chapter {chapter_num} '{chapter_title}': {label} filename '{path.name}' does not match EPUB heading"
                    )
                if contains_html_markup(path.stem):
                    stats["text_mismatch"] += 1
                    status = "❌"
                    issue_desc = (issue_desc + " HTML in filename").strip()
                    issues.append(
                        f"Chapter {chapter_num}: {label} filename has HTML-like markup: {path.name}"
                    )

            # Check parsed.txt vs EPUB
            if "parsed" in text_files:
                parsed_text = text_files["parsed"].read_text(encoding="utf-8")
                parsed_norm = normalize_text(parsed_text)

                if contains_html_markup(parsed_text):
                    stats["text_mismatch"] += 1
                    status = "❌"
                    issue_desc = (issue_desc + " HTML in parsed").strip()
                    issues.append(
                        f"Chapter {chapter_num}: Parsed text still contains HTML tags or markup"
                    )

                is_equal, diff, desc = compare_texts(epub_text, parsed_text)

                parsed_mismatch_recorded = False
                if not is_equal:
                    stats["text_mismatch"] += 1
                    status = "❌"
                    issue_desc = (issue_desc + f" EPUB≠Parsed ({diff:+d})").strip()
                    parsed_mismatch_recorded = True
                    issues.append(f"Chapter {chapter_num}: EPUB text differs from parsed ({desc})")

                epub_start, epub_end = _sample_edges(epub_text)
                if epub_start and epub_start not in parsed_norm:
                    if not parsed_mismatch_recorded:
                        stats["text_mismatch"] += 1
                        parsed_mismatch_recorded = True
                    status = "❌"
                    issue_desc = (issue_desc + " EPUB≠Parsed (start mismatch)").strip()
                    issues.append(f"Chapter {chapter_num}: Parsed missing start sample from EPUB")
                if epub_end and epub_end not in parsed_norm:
                    if not parsed_mismatch_recorded:
                        stats["text_mismatch"] += 1
                        parsed_mismatch_recorded = True
                    status = "❌"
                    issue_desc = (issue_desc + " EPUB≠Parsed (end mismatch)").strip()
                    issues.append(f"Chapter {chapter_num}: Parsed missing end sample from EPUB")

            # Check parsed.txt vs pre-tts.txt
            if "parsed" in text_files and "pre_tts" in text_files:
                parsed_text = text_files["parsed"].read_text(encoding="utf-8")
                pretts_text = text_files["pre_tts"].read_text(encoding="utf-8")
                if contains_html_markup(pretts_text):
                    stats["text_mismatch"] += 1
                    status = "❌"
                    issue_desc = (issue_desc + " HTML in pre-TTS").strip()
                    issues.append(
                        f"Chapter {chapter_num}: PreTTS text still contains HTML tags or markup"
                    )

                pretts_for_compare = strip_formatting_cues(pretts_text)
                parsed_norm = normalize_text(parsed_text)
                pretts_norm = normalize_text(pretts_for_compare)
                diff = len(parsed_norm) - len(pretts_norm)
                allowed_diff = max(50, int(len(parsed_norm) * 0.05))

                if abs(diff) > allowed_diff:
                    stats["parsed_pretts_diff"] += 1
                    status = "❌" if status == "✅" else status
                    issue_desc = (issue_desc + f" Parsed≠PreTTS ({diff:+d})").strip()
                    issues.append(
                        f"Chapter {chapter_num} '{chapter_title}': Parsed differs from PreTTS by {diff} chars - TEXT WAS MODIFIED BEFORE TTS!"
                    )
                    parsed_start, parsed_end = _sample_edges(parsed_text)
                    if parsed_start and parsed_start not in pretts_norm:
                        issue_desc = (issue_desc + " Parsed≠PreTTS (start mismatch)").strip()
                        issues.append(
                            f"Chapter {chapter_num}: PreTTS missing start sample from parsed"
                        )
                    if parsed_end and parsed_end not in pretts_norm:
                        issue_desc = (issue_desc + " Parsed≠PreTTS (end mismatch)").strip()
                        issues.append(
                            f"Chapter {chapter_num}: PreTTS missing end sample from parsed"
                        )

            # Track hashes for duplication detection
            base_text = text_files.get("pre_tts") or text_files.get("parsed")
            if base_text and base_text.exists():
                h = hash_text(base_text.read_text(encoding="utf-8"))
                text_hashes.setdefault(h, []).append(chapter_num)
                chapter_text_hash[chapter_num] = h

        # Find MP3
        mp3_file = (
            mp3_index.get(norm_title)
            or find_mp3_by_title(output_dir, chapter_title)
            or find_mp3_file(output_dir, chapter_num)
        )

        if mp3_file is None:
            stats["missing_mp3"] += 1
            if status == "✅":
                status = "❌"
            issue_desc = (issue_desc + " No MP3").strip()
            issues.append(f"Chapter {chapter_num}: Missing MP3 file")
        else:
            mp3_norm_title = normalized_file_title(mp3_file)
            if expected_titles and not any(
                titles_align(t, mp3_norm_title) for t in expected_titles
            ):
                stats["text_mismatch"] += 1
                if status == "✅":
                    status = "❌"
                issue_desc = (issue_desc + " MP3 name mismatch").strip()
                issues.append(
                    f"Chapter {chapter_num} '{chapter_title}': MP3 filename '{mp3_file.name}' does not match EPUB heading"
                )
            if contains_html_markup(mp3_file.stem):
                stats["text_mismatch"] += 1
                if status == "✅":
                    status = "❌"
                issue_desc = (issue_desc + " MP3 filename has HTML").strip()
                issues.append(
                    f"Chapter {chapter_num}: MP3 filename contains HTML/markup: {mp3_file.name}"
                )

            # Validate MP3 duration
            if "pre_tts" in text_files:
                pretts_text = text_files["pre_tts"].read_text(encoding="utf-8")
                pretts_len = len(normalize_text(pretts_text))
                if pretts_len >= 5000:
                    tolerance = 0.35 if pretts_len < 20000 else 0.25
                    result = validator.validate_duration(pretts_text, mp3_file, tolerance=tolerance)

                    if not result.is_valid:
                        stats["duration_mismatch"] += 1
                        if status == "✅":
                            status = "⚠️ "
                        issue_desc = (
                            issue_desc + f" Duration({result.duration_diff_percent:+.0f}%)"
                        ).strip()

            try:
                base_hash = chapter_text_hash.get(chapter_num)
                if base_hash and len(normalize_text(epub_text)) >= 400:
                    audio_hash = hash_file(mp3_file)
                    existing = audio_hashes.get(audio_hash)
                    if existing and existing.get("text_hash") != base_hash:
                        stats["audio_duplicate"] += 1
                        stats["text_mismatch"] += 1
                        if status == "✅":
                            status = "❌"
                        issue_desc = (issue_desc + " MP3 duplicado").strip()
                        issues.append(
                            "Duplicate audio detected between chapters: "
                            f"{existing.get('chapter')} and {chapter_num}"
                        )
                    else:
                        audio_hashes[audio_hash] = {
                            "chapter": chapter_num,
                            "text_hash": base_hash,
                        }
            except Exception as exc:
                issues.append(f"Chapter {chapter_num}: audio hash check failed ({exc})")

        if status == "✅":
            stats["perfect"] += 1

        # Print row
        epub_len = len(epub_text) if epub_text else 0
        parsed_len = (
            len(text_files.get("parsed", Path()).read_text(encoding="utf-8"))
            if "parsed" in text_files
            else 0
        )
        pretts_len = (
            len(text_files.get("pre_tts", Path()).read_text(encoding="utf-8"))
            if "pre_tts" in text_files
            else 0
        )
        mp3_size = mp3_file.stat().st_size // 1024 if mp3_file else 0

        print(
            f"{chapter_num:<4} {status:<12} {epub_len:<8} {parsed_len:<8} {pretts_len:<8} {mp3_size:<8} {issue_desc}"
        )

    # Summary
    print("\n" + "=" * 70)
    print("📊 RESUMO DA VALIDAÇÃO")
    print("=" * 70)
    print(f"Total de capítulos no EPUB: {stats['total_chapters']}")
    print(f"✅ Capítulos perfeitos: {stats['perfect']}")
    print(f"⚠️  Cache faltando: {stats['missing_cache']}")
    print(f"❌ EPUB ≠ Parsed: {stats['text_mismatch']}")
    print(f"⚠️  Parsed ≠ PreTTS: {stats['parsed_pretts_diff']}")
    print(f"❌ MP3 faltando: {stats['missing_mp3']}")
    print(f"⚠️  Duração incorreta: {stats['duration_mismatch']}")
    print(f"❌ Áudio duplicado: {stats['audio_duplicate']}")

    if issues:
        print("\n" + "=" * 70)
        print("🔥 PROBLEMAS CRÍTICOS ENCONTRADOS")
        print("=" * 70)
        for issue in issues:
            print(f"  • {issue}")

    # Duplicate detection
    dup_groups = [ch_list for ch_list in text_hashes.values() if len(ch_list) > 1]
    if dup_groups:
        print("\n⚠️  CONTEÚDO DUPLICADO DETECTADO ENTRE CAPÍTULOS")
        for group in dup_groups:
            print(f"  • Capítulos: {', '.join(map(str, group))}")
        stats["text_mismatch"] += len(dup_groups)
        issues.append("Conteúdo duplicado detectado entre capítulos")

    audio_dupes = detect_duplicate_audio_files(output_dir)
    if audio_dupes:
        print("\n⚠️  ÁUDIO DUPLICADO DETECTADO ENTRE ARQUIVOS")
        for group in audio_dupes:
            labels = ", ".join(path.name for path in group)
            print(f"  • Arquivos: {labels}")
        stats["audio_duplicate"] += len(audio_dupes)
        issues.append("Arquivos de áudio duplicados detectados (hash match)")

    print("\n" + "=" * 70)
    if stats["parsed_pretts_diff"] > 0 or stats["text_mismatch"] > 0:
        print("❌ VALIDAÇÃO FALHOU: Texto foi modificado durante conversão!")
        print("   O áudio NÃO contém o texto completo do EPUB original.")
    elif stats["missing_mp3"] > 0:
        print("⚠️  VALIDAÇÃO INCOMPLETA: Alguns MP3s faltando")
    elif stats["perfect"] == stats["total_chapters"]:
        print("✅ VALIDAÇÃO PASSOU: Todos os capítulos estão íntegros!")
    else:
        print("⚠️  VALIDAÇÃO COM AVISOS: Verifique os detalhes acima")
    print("=" * 70 + "\n")

    return stats, issues


def auto_fix(
    epub_path: Path,
    output_dir: Path,
    engine: str = "edge",
    voice: str | None = None,
    cache_dir: Path | None = None,
):
    """
    Reprocessa o livro inteiro com cache limpo para corrigir capítulos faltantes/divergentes.
    """
    print("\n🔄 AUTO-FIX: limpando cache e reconvertendo livro completo...")
    if cache_dir is None:
        safe_name = FileManager.sanitize_filename(epub_path.stem) or "livro"
        cache_dir = resolve_cache_root() / safe_name
    reader = EbookReader(str(epub_path))
    config = ConversionConfig(
        engine=engine,
        voice=voice or "",
        output_dir=output_dir,
        cache_dir=cache_dir,
        book_title=epub_path.stem,
        preserve_all_chapters=True,
        force_reprocess=True,
        clear_cache=True,
        auto_validate_output=False,  # evita loops
        auto_fix_output=False,  # evita loops
    )
    converter = AudioConverter()
    asyncio.run(converter.convert(reader, config))


def extract_problem_chapters(issues: List[str]) -> List[int]:
    """Extract chapter numbers from validation issues."""
    chapters: set[int] = set()
    for issue in issues:
        match = re.search(r"\bChapter\s+(\d+)\b", issue)
        if match:
            chapters.add(int(match.group(1)))
            continue
        cap_match = re.search(r"\bCapítulos?:\s*([0-9,\s]+)", issue)
        if cap_match:
            for part in cap_match.group(1).split(","):
                part = part.strip()
                if part.isdigit():
                    chapters.add(int(part))
    return sorted(chapters)


def auto_fix_partial(
    epub_path: Path,
    output_dir: Path,
    chapters: List[int],
    *,
    engine: str = "edge",
    voice: str | None = None,
    cache_dir: Path | None = None,
) -> None:
    """Reprocess only the specified chapters."""
    if not chapters:
        auto_fix(epub_path, output_dir, engine=engine, voice=voice, cache_dir=cache_dir)
        return

    print(f"\n🔄 AUTO-FIX: reconvertendo {len(chapters)} capítulo(s)...")
    if cache_dir is None:
        safe_name = FileManager.sanitize_filename(epub_path.stem) or "livro"
        cache_dir = resolve_cache_root() / safe_name
    reader = EbookReader(str(epub_path))
    config = ConversionConfig(
        engine=engine,
        voice=voice or "",
        output_dir=output_dir,
        cache_dir=cache_dir,
        book_title=epub_path.stem,
        preserve_all_chapters=True,
        force_reprocess=True,
        clear_cache=False,
        auto_validate_output=False,  # evita loops
        auto_fix_output=False,  # evita loops
    )
    config.extra["chapter_whitelist"] = ",".join(str(ch) for ch in chapters)
    converter = AudioConverter()
    asyncio.run(converter.convert(reader, config))


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Validate EPUB → MP3 conversion integrity")
    parser.add_argument("epub_file", type=Path, help="Path to EPUB file")
    parser.add_argument("--output-dir", type=Path, help="Output directory with MP3s")
    parser.add_argument(
        "--auto-fix", action="store_true", help="Reconvert livro inteiro se houver problemas"
    )
    parser.add_argument(
        "--engine", default="edge", help="Engine TTS para auto-fix (ex: edge, coqui, piper)"
    )
    parser.add_argument("--voice", default=None, help="Voz TTS (opcional) para auto-fix")

    args = parser.parse_args()

    if not args.epub_file.exists():
        print(f"❌ ERROR: File not found: {args.epub_file}")
        sys.exit(1)

    stats, issues = validate_book(args.epub_file, args.output_dir)

    if args.auto_fix and (issues or stats["missing_mp3"] or stats["text_mismatch"]):
        out_dir = args.output_dir
        if out_dir is None:
            out_dir = Path("output") / args.epub_file.stem
        auto_fix(args.epub_file, out_dir, engine=args.engine, voice=args.voice)
        print("\n✅ Auto-fix concluído. Reexecutando validação...\n")
        validate_book(args.epub_file, out_dir)
