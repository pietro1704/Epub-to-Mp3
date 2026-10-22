"""Last-resort recovery keeps explicit engine intent and restores temporary state."""

import asyncio
import os
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock, patch

import pytest
from src import last_resort_recovery as recovery
from src._retry_mixin import _RetryMixin

import validate_conversion


@pytest.fixture
def recovery_host(monkeypatch):
    host = _RetryMixin()
    host.verbose = False
    host._cli_fallback_engine = "none"
    host._active_config = SimpleNamespace(engine="edge", voice="fixture", primary_language="pt-BR")
    reader = SimpleNamespace(title="Fixture", language="pt-BR")
    monkeypatch.setattr("src.ebook_reader.EbookReader", lambda _: reader)
    monkeypatch.setattr("src.tts.factory.TTSFactory", lambda: SimpleNamespace(available_engines=lambda: ["edge", "piper"]))
    app = SimpleNamespace(
        config=SimpleNamespace(create_conversion_config=lambda **_: SimpleNamespace()),
        FOOTNOTE_CONTEXT_WORDS=5, _generate_structure_items=lambda *_, **__: [],
        _apply_text_transforms=lambda *_, **__: [], _apply_structure_to_reader=lambda *_: None,
    )
    monkeypatch.setattr("python_app.main.ConverterApplication", lambda: app)
    monkeypatch.setattr(recovery, "ConversionConfig", lambda **kwargs: SimpleNamespace(extra={}, **kwargs))
    validator = Mock(return_value=({}, []))
    monkeypatch.setattr(validate_conversion, "validate_book", validator)
    return host, reader, validator


@pytest.mark.asyncio
async def test_last_resort_preserves_explicit_engine_language_and_environment(recovery_host, tmp_path):
    host, reader, validator = recovery_host
    observed = {}

    async def convert(actual_reader, config):
        assert actual_reader is reader
        observed.update(config=config, environment=dict(os.environ))

    host.convert = AsyncMock(side_effect=convert)
    with patch.dict(os.environ, {"CHAPTER_PARALLEL_COUNT": "9"}, clear=True):
        assert await host._last_resort_recovery(
            epub_path=tmp_path / "book.epub", output_dir=tmp_path, chapter_selectors=None, reason="fixture"
        )
        assert dict(os.environ) == {"CHAPTER_PARALLEL_COUNT": "9"}
    assert observed["config"].engine == "edge"
    assert observed["config"].primary_language == "pt-BR"
    assert observed["config"].languages == ["pt-BR"]
    assert observed["environment"]["CHAPTER_PARALLEL_COUNT"] == "1"
    assert observed["environment"]["EDGE_ENABLE_PARALLEL"] == "false"
    validator.assert_called_once_with(tmp_path / "book.epub", tmp_path, cache_dir=None, duration_tolerance=1.50)


@pytest.mark.asyncio
@pytest.mark.parametrize("error", [RuntimeError("conversion failed"), asyncio.CancelledError()])
async def test_last_resort_failure_or_cancellation_restores_environment(recovery_host, tmp_path, error):
    host, _, validator = recovery_host
    host.convert = AsyncMock(side_effect=error)
    with patch.dict(os.environ, {"CHAPTER_PARALLEL_COUNT": "9"}, clear=True):
        arguments = dict(epub_path=tmp_path / "book.epub", output_dir=tmp_path, chapter_selectors=None, reason="fixture")
        if isinstance(error, asyncio.CancelledError):
            with pytest.raises(asyncio.CancelledError):
                await host._last_resort_recovery(**arguments)
        else:
            assert not await host._last_resort_recovery(**arguments)
        assert dict(os.environ) == {"CHAPTER_PARALLEL_COUNT": "9"}
    validator.assert_not_called()
