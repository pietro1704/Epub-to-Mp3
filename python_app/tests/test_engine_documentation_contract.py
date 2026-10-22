"""Documentation and public-engine contract checks for APP-020."""

from __future__ import annotations

import argparse
import re
from pathlib import Path
from types import SimpleNamespace

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]


def test_web_readme_documents_embedded_development_without_a_python_backend() -> None:
    readme = (REPO_ROOT / "web" / "README.md").read_text(encoding="utf-8")
    assert "mise exec -- npm run dev" in readme
    assert "embedded Rust/WASM" in readme
    assert "BrowserConversionClient" in readme
    assert "python -m uvicorn" not in readme


def test_root_readme_documents_only_exposed_engines() -> None:
    readme = (REPO_ROOT / "README.md").read_text(encoding="utf-8")
    assert "Edge-TTS" in readme
    assert "Piper" in readme
    assert not re.search(r"\b(kokoro|coqui|spark)\b", readme, re.IGNORECASE)


def test_web_readme_documents_the_browser_provider_and_export_boundary() -> None:
    readme = (REPO_ROOT / "web" / "README.md").read_text(encoding="utf-8")
    assert "Piper" in readme
    assert "pt_BR-faber-medium" in readme
    assert "explicit model installation" in readme
    assert "listening-only; MP3 export requires Piper" in readme
    assert "must fail explicitly rather than switch to an HTTP server" in readme
    assert "GET /api/voices" not in readme


def test_cli_completion_lists_only_supported_engine_values() -> None:
    completion = (REPO_ROOT / "shell-completion.zsh").read_text(encoding="utf-8")
    assert ":(auto edge piper)" in completion
    assert not re.search(r"\b(coqui|kokoro|spark)\b", completion, re.IGNORECASE)


def test_cli_and_factory_expose_only_supported_engine_names() -> None:
    from src.cli_arguments import add_conversion_arguments

    parser = argparse.ArgumentParser()
    add_conversion_arguments(
        parser, include_menu_flag=True, input_required=True,
        namespace=SimpleNamespace(FilesCompleter=None, ChoicesCompleter=None),
    )
    for engine in ("auto", "edge", "piper"):
        assert parser.parse_args(["book.epub", "--engine", engine]).engine == engine
    for engine in ("coqui", "kokoro", "spark"):
        with pytest.raises(SystemExit):
            parser.parse_args(["book.epub", "--engine", engine])
    factory = (REPO_ROOT / "python_app" / "src" / "tts" / "factory.py").read_text(encoding="utf-8")
    assert 'engines = ["edge"]' in factory
    assert 'engines.append("piper")' in factory
    assert not re.search(r"\b(coqui|kokoro|spark)\b", factory, re.IGNORECASE)


def test_voices_endpoint_delegates_to_the_curated_provider_catalog() -> None:
    source_root = REPO_ROOT / "python_app" / "src"
    bootstrap = (source_root / "server_bootstrap_voice_policy.py").read_text(encoding="utf-8")
    implementation = (source_root / "server_voice_routes.py").read_text(encoding="utf-8")
    assert '_runtime.app.get("/api/voices")' in bootstrap
    assert "_runtime._server_server_voice_routes.list_available_voices" in bootstrap
    assert '"voices": provider.get_voice_suggestions()' in implementation


def test_ui_does_not_advertise_removed_engine_chain() -> None:
    translation_root = REPO_ROOT / "web" / "src" / "i18n"
    composition = (translation_root / "translations.ts").read_text(encoding="utf-8")
    owners = re.findall(r"from '\./([^']+)'", composition)
    assert owners, "The translation composition must include its active owners"
    translations = "\n".join([
        composition,
        *((translation_root / f"{owner}.ts").read_text(encoding="utf-8") for owner in owners),
    ])
    from src.cli_arguments_input_engine import add_input_engine_arguments

    parser = argparse.ArgumentParser()
    add_input_engine_arguments(parser, True)
    cli_help = " ".join(parser.format_help().split())
    assert "Edge -> Piper" in cli_help
    assert "Edge-only" not in cli_help
    assert "Edge → Piper" in translations
    assert "XTTS" not in translations
    assert "Kokoro" not in translations
    assert "Coqui" not in translations
    assert "Spark" not in translations


def test_voice_catalog_contract_is_exactly_edge_piper_and_auto() -> None:
    from src.config import VoiceConfigProvider

    assert set(VoiceConfigProvider().get_voice_suggestions()) == {"edge", "piper", "auto"}
