from __future__ import annotations

import importlib.util
import sys
from importlib.machinery import SourceFileLoader
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
CONVERT_PATH = PROJECT_ROOT / "python_app" / "convert"
PYTHON_APP_ROOT = PROJECT_ROOT / "python_app"


def _load_convert_module():
    if str(PYTHON_APP_ROOT) not in sys.path:
        sys.path.insert(0, str(PYTHON_APP_ROOT))
    loader = SourceFileLoader("python_app_convert_entrypoint", str(CONVERT_PATH))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def test_convert_entrypoint_keeps_input_when_option_comes_first(monkeypatch, tmp_path):
    module = _load_convert_module()
    book = tmp_path / "book.epub"
    book.write_text("dummy", encoding="utf-8")
    captured = {}

    class DummyApp:
        def __init__(self, ui_language=None):
            captured["ui_language"] = ui_language

        def run(self, args):
            captured["input_file"] = args.input_file
            captured["menu"] = args.menu
            return 0

    monkeypatch.setattr(module, "ConverterApplication", DummyApp)
    monkeypatch.setattr(sys, "argv", ["python_app/convert", "--menu", str(book)])

    assert module.main() == 0
    assert captured["input_file"] == str(book)
    assert captured["menu"] is True


def test_convert_entrypoint_rejects_menu_without_input(monkeypatch):
    module = _load_convert_module()
    monkeypatch.setattr(sys, "argv", ["python_app/convert", "--menu"])

    try:
        module.main()
    except SystemExit as exc:
        assert exc.code == 2
    else:
        raise AssertionError("Expected SystemExit for --menu without input")


def test_fuzzy_find_book_matches_misspelled_query(monkeypatch, tmp_path):
    module = _load_convert_module()
    downloads = tmp_path / "Downloads"
    downloads.mkdir()
    target = downloads / "O_louco_de_Deus_no_fim_do_mundo.epub"
    target.write_text("x", encoding="utf-8")
    (downloads / "Other_Book.epub").write_text("y", encoding="utf-8")

    monkeypatch.setattr(module, "_FUZZY_SEARCH_DIRS", (downloads,))

    # typo: "loudo" instead of "louco"; leading "downloads" directory name
    match = module._fuzzy_find_book("downloads o loudo de deus")
    assert match == target

    assert module._fuzzy_find_book("completely unrelated qwerty") is None
