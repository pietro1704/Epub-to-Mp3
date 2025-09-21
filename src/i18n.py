# -*- coding: utf-8 -*-
"""Minimal localisation support for CLI output."""

from __future__ import annotations

import locale
import os
from dataclasses import dataclass, field
from typing import Dict


def detect_system_language() -> str:
    candidates = [
        os.environ.get("LANG"),
        locale.getlocale()[0] if hasattr(locale, "getlocale") else None,
        locale.getdefaultlocale()[0] if hasattr(locale, "getdefaultlocale") else None,
    ]
    for candidate in candidates:
        if not candidate:
            continue
        candidate = str(candidate)
        if not candidate:
            continue
        lang = candidate.replace("-", "_").split("_", 1)[0].lower()
        if lang in ("pt", "en"):
            return lang
    return "en"


TRANSLATIONS: Dict[str, Dict[str, str]] = {
    "en": {
        "book_label": "📚 Book",
        "author_label": "👤 Author",
        "chapters_label": "📄 Chapters",
        "detected_languages": "🌐 Detected languages: {languages} | Primary: {primary}",
        "choose_engine_title": "\n🎵 Choose TTS Engine:",
        "engine_option_edge": "Edge-TTS (Microsoft, online, fast)",
        "engine_option_coqui": "Coqui TTS (Local AI, high quality)",
        "engine_option_piper": "Piper TTS (Local, lightweight)",
        "engine_option_exit": "Exit",
        "select_engine_prompt": "Select engine (1-3): ",
        "invalid_option": "Invalid option. Please try again.",
        "voice_title": "\n🗣️ Choose Voice:",
        "press_enter_keep_default": "Press Enter to keep the default",
        "select_voice_prompt": "Select voice: ",
        "model_title": "\n🤖 Choose Model:",
        "select_model_prompt": "Select model: ",
        "piper_models_title": "\n🎭 Piper models:",
        "piper_models_hint": "Place .onnx model files in the 'models' directory",
        "piper_models_prompt": "Press Enter to continue: ",
        "footnote_title": "\n📝 Footnote handling:",
        "footnote_option_inline": "Read inline",
        "footnote_option_chapter_end": "Read at the end of each chapter",
        "footnote_option_skip": "Skip footnotes",
        "footnote_option_cancel": "Cancel conversion",
        "select_footnote_prompt": "Select option (0-3): ",
        "summary_title": "\n📝 Summary:",
        "summary_engine": "  Engine: {value}",
        "summary_voice": "  Voice/Model: {value}",
        "summary_footnotes": "  Footnotes: {value}",
        "summary_languages": "  Languages: {value}",
        "auto_start_notice": "\nStarting conversion automatically...",
        "language_profile_start": "\n🧠 Analysing book language...",
        "preprocess_chapter": "🔍 Preparing chapter {index}: {title}",
        "engine_selected": "→ Engine selected: {option}",
        "voice_selected": "→ Voice selected: {option}",
        "model_selected": "→ Model selected: {option}",
        "footnote_selected": "→ Footnote mode: {option}",
        "default_suffix": " (default)",
        "conversion_start": "\n🚀 Starting conversion: {title} ({chapters} chapters)",
        "conversion_output": "💾 Output: {path}",
        "conversion_engine_voice": "🎙️ Engine: {engine} | Voice: {voice}",
        "conversion_parallel": "⚙️ Parallel workers: {workers}",
        "conversion_languages": "🌐 Languages: {languages}",
        "progress_description": "Converting chapters",
        "conversion_results_title": "\n📊 Conversion Results:",
        "conversion_results_success": "  ✅ Converted: {converted}/{total}",
        "conversion_results_files": "  📁 Files: {files}",
        "conversion_results_errors": "  ❌ Errors: {errors}",
        "requirements_not_found": "⚠️ requirements.txt not found. Install dependencies manually.",
        "installing_requirements": "\n📦 Installing dependencies from requirements.txt...",
        "requirements_success": "✅ Dependencies installed. Resuming conversion...\n",
        "requirements_failure": "❌ Failed to install dependencies. Run: pip install -r requirements.txt",
        "language_prompt": "Unable to detect the primary language automatically.\nEnter comma-separated languages (e.g., pt,en,es). Press Enter for '{default}'.\n> ",
        "selectors_not_found": "⚠️ No chapters matched: {selectors}. Available indices: {available}",
        "file_not_found": "❌ File not found: {path}",
        "unexpected_error": "❌ Error: {error}",
        "structure_item_entry": "  {name} ({chars} chars)",
        "status_cached": "✅ already cached",
        "status_preparing": "⏳ preparing chapter",
        "status_waiting_slot": "⌛ waiting for available slot",
        "status_insufficient_text": "⚠️ insufficient text",
        "status_synthesizing": "⏳ synthesizing",
        "status_convert_mp3": "⏳ converting to MP3",
        "status_mp3_failed": "⚠️ MP3 conversion failed",
        "status_complete": "✅ completed",
        "status_playing": "🔊 playing",
        "status_play_unavailable": "⚠️ playback unavailable",
        "status_internal_error": "❌ internal error",
        "status_synthesis_failed": "⚠️ synthesis failed",
        "status_synthesis_failed_detail": "⚠️ synthesis failed (reason: {error})",
        "error_conversion_failed": "{chapter}: conversion failed",
    },
    "pt": {
        "book_label": "📚 Livro",
        "author_label": "👤 Autor",
        "chapters_label": "📄 Capítulos",
        "detected_languages": "🌐 Idiomas detectados: {languages} | Principal: {primary}",
        "choose_engine_title": "\n🎵 Escolha o motor de TTS:",
        "engine_option_edge": "Edge-TTS (Microsoft, online, rápido)",
        "engine_option_coqui": "Coqui TTS (IA local, alta qualidade)",
        "engine_option_piper": "Piper TTS (Local, leve)",
        "engine_option_exit": "Sair",
        "select_engine_prompt": "Selecione o motor (1-3): ",
        "invalid_option": "Opção inválida. Tente novamente.",
        "voice_title": "\n🗣️ Escolha a voz:",
        "press_enter_keep_default": "Pressione Enter para manter o padrão",
        "select_voice_prompt": "Selecione a voz: ",
        "model_title": "\n🤖 Escolha o modelo:",
        "select_model_prompt": "Selecione o modelo: ",
        "piper_models_title": "\n🎭 Modelos Piper:",
        "piper_models_hint": "Coloque arquivos .onnx na pasta 'models'",
        "piper_models_prompt": "Pressione Enter para continuar: ",
        "footnote_title": "\n📝 Notas de rodapé:",
        "footnote_option_inline": "Ler no fluxo",
        "footnote_option_chapter_end": "Ler ao fim de cada capítulo",
        "footnote_option_skip": "Ignorar notas",
        "footnote_option_cancel": "Cancelar conversão",
        "select_footnote_prompt": "Selecione (0-3): ",
        "summary_title": "\n📝 Resumo:",
        "summary_engine": "  Motor: {value}",
        "summary_voice": "  Voz/Modelo: {value}",
        "summary_footnotes": "  Notas: {value}",
        "summary_languages": "  Idiomas: {value}",
        "auto_start_notice": "\nIniciando conversão automaticamente...",
        "language_profile_start": "\n🧠 Analisando idioma do livro...",
        "preprocess_chapter": "🔍 Preparando capítulo {index}: {title}",
        "engine_selected": "→ Motor selecionado: {option}",
        "voice_selected": "→ Voz selecionada: {option}",
        "model_selected": "→ Modelo selecionado: {option}",
        "footnote_selected": "→ Modo das notas: {option}",
        "default_suffix": " (padrão)",
        "conversion_start": "\n🚀 Iniciando conversão: {title} ({chapters} capítulos)",
        "conversion_output": "💾 Saída: {path}",
        "conversion_engine_voice": "🎙️ Motor: {engine} | Voz: {voice}",
        "conversion_parallel": "⚙️ Processos paralelos: {workers}",
        "conversion_languages": "🌐 Idiomas: {languages}",
        "progress_description": "Convertendo capítulos",
        "conversion_results_title": "\n📊 Resultados:",
        "conversion_results_success": "  ✅ Convertidos: {converted}/{total}",
        "conversion_results_files": "  📁 Arquivos: {files}",
        "conversion_results_errors": "  ❌ Erros: {errors}",
        "requirements_not_found": "⚠️ requirements.txt não encontrado. Instale as dependências manualmente.",
        "installing_requirements": "\n📦 Instalando dependências do requirements.txt...",
        "requirements_success": "✅ Dependências instaladas. Retomando conversão...\n",
        "requirements_failure": "❌ Falha ao instalar dependências. Execute: pip install -r requirements.txt",
        "language_prompt": "Não foi possível identificar o idioma principal automaticamente.\nInforme os idiomas separados por vírgula (ex.: pt,en,es). Pressione Enter para '{default}'.\n> ",
        "selectors_not_found": "⚠️ Nenhum capítulo correspondeu a: {selectors}. Índices disponíveis: {available}",
        "file_not_found": "❌ Arquivo não encontrado: {path}",
        "unexpected_error": "❌ Erro: {error}",
        "structure_item_entry": "  {name} ({chars} caracteres)",
        "status_cached": "✅ já existia",
        "status_preparing": "⏳ preparando capítulo",
        "status_waiting_slot": "⌛ aguardando vaga disponível",
        "status_insufficient_text": "⚠️ texto insuficiente",
        "status_synthesizing": "⏳ sintetizando",
        "status_convert_mp3": "⏳ convertendo para MP3",
        "status_mp3_failed": "⚠️ MP3 falhou",
        "status_complete": "✅ concluído",
        "status_playing": "🔊 reproduzindo",
        "status_play_unavailable": "⚠️ reprodução indisponível",
        "status_internal_error": "❌ erro interno",
        "status_synthesis_failed": "⚠️ síntese falhou",
        "status_synthesis_failed_detail": "⚠️ síntese falhou (motivo: {error})",
        "error_conversion_failed": "{chapter}: conversão falhou",
    },
}


@dataclass
class Localization:
    language: str
    default_color: str = field(default="\033[36m")  # cyan
    reset_color: str = field(default="\033[0m")

    def __post_init__(self) -> None:
        if self.language not in TRANSLATIONS:
            self.language = "en"

    def t(self, key: str, **kwargs) -> str:
        template = TRANSLATIONS.get(self.language, {}).get(key)
        if template is None:
            template = TRANSLATIONS["en"].get(key, key)
        return template.format(**kwargs)

    def highlight_default(self, text: str) -> str:
        return f"{self.default_color}{text}{self.reset_color}"


def get_localization(language: str | None = None) -> Localization:
    language = language or detect_system_language()
    return Localization(language)


__all__ = ["Localization", "get_localization", "detect_system_language"]
