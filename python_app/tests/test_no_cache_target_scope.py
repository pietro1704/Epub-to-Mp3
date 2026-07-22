from pathlib import Path
from types import SimpleNamespace

from main import ConverterApplication
from src.cache_manager import CacheManager


def _make_book_caches(tmp_path):
    cache_root = tmp_path / "cache"
    cache_root.mkdir()
    books = [tmp_path / "book-a.epub", tmp_path / "book-b.epub"]
    for index, book in enumerate(books):
        book.write_bytes(f"book {index}".encode())
        text_dir = cache_root / book.stem / "text"
        text_dir.mkdir(parents=True)
        (text_dir / "chapter.txt").write_text(book.stem, encoding="utf-8")
    return cache_root, books


def test_no_cache_clears_only_target_book_cache(tmp_path):
    cache_root, (book_a, book_b) = _make_book_caches(tmp_path)
    cache_manager = CacheManager(cache_dir=cache_root)
    app = ConverterApplication.__new__(ConverterApplication)

    app._clear_no_cache_target(cache_manager, book_a, SimpleNamespace(title="Book A"))

    assert not (cache_root / "book-a").exists()
    assert (cache_root / "book-b" / "text" / "chapter.txt").read_text(encoding="utf-8") == "book-b"


def test_batch_no_cache_clears_each_target_without_global_wipe(tmp_path):
    cache_root, books = _make_book_caches(tmp_path)
    cache_manager = CacheManager(cache_dir=cache_root)
    app = ConverterApplication.__new__(ConverterApplication)
    cache_state_during_batch = []

    def convert_one(args, *, hardware_profile=None):
        target = Path(args.input_file)
        other = books[1] if target == books[0] else books[0]
        cache_state_during_batch.append(
            ((cache_root / target.stem).exists(), (cache_root / other.stem).exists())
        )
        app._clear_no_cache_target(cache_manager, target, SimpleNamespace(title=target.stem))
        return 0

    app._run_single_conversion = convert_one
    args = SimpleNamespace(
        batch_stop_on_error=False,
        verify_only=False,
        fix_mode=False,
        no_cache=True,
    )

    assert app._run_batch(args, books, hardware_profile=None) == 0
    assert cache_state_during_batch == [(True, True), (True, False)]
    assert not (cache_root / "book-a").exists()
    assert not (cache_root / "book-b").exists()
