"""Legacy iOS Python decomposition preserves the public contract without native execution."""

from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

import pytest
from python_app.src import ebook_reader
from python_app.src import ios_book_conversion, ios_entrypoints


@pytest.fixture
def conversion(tmp_path, monkeypatch):
    source = tmp_path / "book.epub"
    source.write_bytes(b"fixture")
    chapters = [SimpleNamespace(index="7.13", name="Chapter", text="spoken content", level=2)]
    reader = SimpleNamespace(
        title="Fixture", author="Author", language="pt-BR",
        get_chapter_structure=lambda **_: chapters,
    )
    reader_factory = Mock(return_value=reader)
    monkeypatch.setattr(ebook_reader, "EbookReader", reader_factory)
    monkeypatch.setattr(ios_entrypoints, "_override_persistent_paths", lambda cache, output: Path(cache))
    monkeypatch.setattr(ios_entrypoints, "_validate_audio_completeness", lambda path, chars: (True, 100.0))
    arguments = dict(epub_path=str(source), output_dir=str(tmp_path / "out"), cache_dir=str(tmp_path / "cache"))
    return source, reader_factory, arguments


def test_public_book_conversion_preserves_signature_owner_callback_and_chapter_identity(conversion, monkeypatch):
    source, reader_factory, arguments = conversion
    assert ios_entrypoints.convert_epub is ios_book_conversion.convert_epub

    def synthesize(text, voice, output, **kwargs):
        assert text == "spoken content"
        assert voice == "pt-BR-FranciscaNeural"
        Path(output).write_bytes(b"audio")
        return output

    callback = Mock(side_effect=synthesize)
    monkeypatch.setattr(ios_entrypoints, "synthesize_chapter_via_transport", callback)
    result = ios_entrypoints.convert_epub(**arguments, bitrate="64k", no_validate=True)
    reader_factory.assert_called_once_with(str(source))
    assert result["manifest"][0]["index"] == "7.13"
    assert result["manifest"][0]["level"] == 2
    assert result["manifest"][0]["status"] == "completed"
    assert result["applied_options"]["bitrate"] == "64k"
    assert "_runtime" not in result["applied_options"]
    callback.assert_called_once()
    assert callback.call_args.kwargs["validate_audio"] is False


def test_book_synthesis_failure_is_reported_on_same_chapter_identity(conversion, monkeypatch):
    _, _, arguments = conversion
    monkeypatch.setattr(ios_entrypoints, "synthesize_chapter_via_transport", Mock(side_effect=RuntimeError("transport failed")))
    result = ios_entrypoints.convert_epub(**arguments)
    assert result["outputs"] == []
    assert result["manifest"][0]["index"] == "7.13"
    assert result["manifest"][0]["status"] == "failed"
    assert result["errors"] == ["chapter 7.13: transport failed"]


def test_book_synthesis_cancellation_propagates(conversion, monkeypatch):
    _, _, arguments = conversion
    monkeypatch.setattr(ios_entrypoints, "synthesize_chapter_via_transport", Mock(side_effect=KeyboardInterrupt))
    with pytest.raises(KeyboardInterrupt):
        ios_entrypoints.convert_epub(**arguments)
