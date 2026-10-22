"""Resolve conversion cache and output artifacts without changing their identity."""

import re
from pathlib import Path
from typing import Dict, List, Optional

from conversion_validation_text import (
    _strip_numeric_prefix,
    _strip_text_suffix,
    normalize_title_key,
)


def find_cache_dir(book_path: Path) -> Path:
    """Find cache directory for a book.

    The same EPUB may produce multiple cache directories (one keyed by the
    raw filename stem and one keyed by the resolved book title). The filename-
    based one is sometimes left empty after the parser promotes to the title-
    based one. We must scan every candidate, and only the ones that actually
    contain a populated ``text/`` subdir count as a hit. Falling back to a
    looser token-based match catches cases where the EPUB filename has noise
    like ``... (Z-Library)`` that the title doesn't share.
    """
    cache_root = Path(".cache")
    if not cache_root.is_dir():
        raise FileNotFoundError(f"Cache root missing: {cache_root}")

    book_name = book_path.stem
    book_lower = book_name.lower()
    book_tokens = [t for t in re.split(r"\W+", book_lower) if len(t) >= 4]

    # Filename and book title often diverge (e.g. ``pg50936-images-3.epub``
    # → ``Man in a Sewing Machine``). Extract the EPUB metadata title and
    # use it as an additional matching hint so caches keyed by title still
    # resolve.
    title_tokens: List[str] = []
    title_lower = ""
    try:
        from python_app.src.ebook_reader import EbookReader as _Reader

        title = _Reader(str(book_path)).title or ""
        title_lower = title.lower()
        title_tokens = [t for t in re.split(r"\W+", title_lower) if len(t) >= 4]
    except Exception:
        pass

    def _populated_text_dir(cache_dir: Path) -> Optional[Path]:
        # The CLI conversion path writes ``text/`` directly under the book
        # cache root; ``--show-structure`` instead writes ``txt/``. Accept
        # both so validation works regardless of which path populated cache.
        for variant in ("text", "txt"):
            direct = cache_dir / variant
            if direct.is_dir() and any(direct.iterdir()):
                # Synthesize a parent that the rest of validate_book treats
                # as the engine_dir (engine_dir / "text" must exist).
                if variant == "text":
                    return cache_dir
                # ``txt`` → make a sibling ``text`` symlink so downstream
                # code (which strictly looks for ``text``) finds it.
                text_link = cache_dir / "text"
                if not text_link.exists():
                    try:
                        text_link.symlink_to(direct.name, target_is_directory=True)
                    except OSError:
                        return None
                return cache_dir
        for engine_dir in cache_dir.iterdir():
            if not engine_dir.is_dir():
                continue
            for variant in ("text", "txt"):
                inner = engine_dir / variant
                if inner.is_dir() and any(inner.iterdir()):
                    if variant == "txt":
                        text_link = engine_dir / "text"
                        if not text_link.exists():
                            try:
                                text_link.symlink_to(inner.name, target_is_directory=True)
                            except OSError:
                                continue
                    return engine_dir
        for subdir in cache_dir.rglob("text"):
            if subdir.is_dir() and any(subdir.iterdir()):
                return subdir.parent
        for subdir in cache_dir.rglob("txt"):
            if subdir.is_dir() and any(subdir.iterdir()):
                parent = subdir.parent
                text_link = parent / "text"
                if not text_link.exists():
                    try:
                        text_link.symlink_to(subdir.name, target_is_directory=True)
                    except OSError:
                        continue
                return parent
        return None

    candidates: list[Path] = []
    for cache_dir in cache_root.iterdir():
        if not cache_dir.is_dir():
            continue
        name_lower = cache_dir.name.lower()
        # Direct substring containment in either direction (filename or title).
        if (
            book_lower in name_lower
            or name_lower in book_lower
            or (title_lower and (title_lower in name_lower or name_lower in title_lower))
        ):
            candidates.append(cache_dir)
            continue
        # Fallback: at least 60% of significant tokens match (filename or title).
        for tokens in (book_tokens, title_tokens):
            if tokens:
                matches = sum(1 for tok in tokens if tok in name_lower)
                if matches / len(tokens) >= 0.6:
                    candidates.append(cache_dir)
                    break

    for cache_dir in candidates:
        engine_dir = _populated_text_dir(cache_dir)
        if engine_dir is not None:
            return engine_dir

    raise FileNotFoundError(f"Cache directory not found for {book_path.name}")


def find_text_files(text_dirs: List[Path], chapter_num) -> Dict[str, Path]:
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
