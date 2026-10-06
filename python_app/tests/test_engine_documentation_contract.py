"""Documentation and public-engine contract checks for APP-020."""

from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


def test_web_readme_uses_the_operational_backend_command() -> None:
    readme = (REPO_ROOT / "web" / "README.md").read_text(encoding="utf-8")
    assert "python -m uvicorn python_app.server:app --reload --port 8000" in readme
    assert "python -m uvicorn main:app" not in readme


def test_root_readme_documents_only_exposed_engines() -> None:
    readme = (REPO_ROOT / "README.md").read_text(encoding="utf-8")
    assert "Edge-TTS" in readme
    assert "Piper" in readme
    assert not re.search(r"\b(kokoro|coqui|spark)\b", readme, re.IGNORECASE)


def test_web_readme_documents_the_public_engine_and_voice_contract() -> None:
    readme = (REPO_ROOT / "web" / "README.md").read_text(encoding="utf-8")
    assert "Edge-TTS" in readme
    assert "Piper" in readme
    assert "auto" in readme
    assert "GET /api/voices" in readme
    assert re.search(r"\b(kokoro|coqui|spark)\b", readme, re.IGNORECASE)
    assert "not supported engines" in readme


def test_cli_completion_lists_only_supported_engine_values() -> None:
    completion = (REPO_ROOT / "shell-completion.zsh").read_text(encoding="utf-8")
    assert ":(auto edge piper)" in completion
    assert not re.search(r"\b(coqui|kokoro|spark)\b", completion, re.IGNORECASE)


def test_cli_and_factory_expose_only_supported_engine_names() -> None:
    cli = (REPO_ROOT / "python_app" / "main.py").read_text(encoding="utf-8")
    factory = (REPO_ROOT / "python_app" / "src" / "tts" / "factory.py").read_text(encoding="utf-8")
    assert 'choices=["auto", "edge", "piper"]' in cli
    assert 'engines = ["edge"]' in factory
    assert 'engines.append("piper")' in factory
    assert not re.search(r"\b(coqui|kokoro|spark)\b", cli, re.IGNORECASE)
    assert not re.search(r"\b(coqui|kokoro|spark)\b", factory, re.IGNORECASE)


def test_voices_endpoint_delegates_to_the_curated_provider_catalog() -> None:
    server = (REPO_ROOT / "python_app" / "server.py").read_text(encoding="utf-8")
    assert '@app.get("/api/voices")' in server
    assert '"voices": provider.get_voice_suggestions()' in server


def test_ui_does_not_advertise_removed_engine_chain() -> None:
    translations = (REPO_ROOT / "web" / "src" / "i18n" / "translations.ts").read_text(
        encoding="utf-8"
    )
    cli_help = (REPO_ROOT / "python_app" / "main.py").read_text(encoding="utf-8")
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
