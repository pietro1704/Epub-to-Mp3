# -*- coding: utf-8 -*-
"""Interactive menu for the CLI converter."""

from __future__ import annotations

from typing import Dict, Optional

from ..config import ConversionConfig, VoiceConfigProvider
from ..ebook_reader import EbookReader
from ..i18n import Localization
from .prompt import TerminalPrompt


class MenuInterface:
    """Simple menu interface following SRP"""

    def __init__(self, localization: Localization) -> None:
        self.voice_provider = VoiceConfigProvider()
        self.prompt = TerminalPrompt()
        self.loc = localization

    def get_conversion_config(
        self,
        reader: EbookReader,
        language_profile=None,
        formatting_cues: Optional[bool] = None,
    ) -> Optional[ConversionConfig]:
        """Get conversion configuration through interactive menu"""

        print(f"\n{self.loc.t('book_label')}: {reader.title}")
        print(f"{self.loc.t('author_label')}: {reader.author}")
        print(f"{self.loc.t('chapters_label')}: {len(reader.get_chapters())}")
        if language_profile:
            languages = ", ".join(language_profile.languages or []) or "(auto)"
            primary = language_profile.primary or "(auto)"
            print(self.loc.t("detected_languages", languages=languages, primary=primary))

        engine = self._choose_engine()
        if not engine:
            return None

        voice = self._choose_voice(engine)

        footnote_mode = self._choose_footnote_mode()
        if footnote_mode is None:
            return None
        cues_enabled = formatting_cues
        if cues_enabled is None:
            cues_enabled = self._choose_formatting_cues()
            if cues_enabled is None:
                return None

        config = ConversionConfig(
            engine=engine,
            voice=voice,
            book_title=reader.title,
            footnote_mode=footnote_mode,
            footnote_context_words=8,
            speak_formatting_cues=bool(cues_enabled),
            formatting_locale=self.loc.language,
        )

        print(self.loc.t("summary_title"))
        print(self.loc.t("summary_engine", value=config.engine))
        print(self.loc.t("summary_voice", value=config.voice or "(auto)"))
        print(self.loc.t("summary_footnotes", value=config.footnote_mode))

        if language_profile and language_profile.languages:
            languages_display = ", ".join(language_profile.languages)
        elif getattr(config, "languages", None):
            languages_display = ", ".join(config.languages)
        else:
            languages_display = config.primary_language or "auto"
        if not languages_display or languages_display.lower() == "auto":
            languages_display = "(auto)"
        print(self.loc.t("summary_languages", value=languages_display))

        print(self.loc.highlight_default(self.loc.t("auto_start_notice")))

        return config

    def _choose_formatting_cues(self) -> Optional[bool]:
        options = {
            "1": (True, self.loc.t("formatting_cues_enable")),
            "2": (False, self.loc.t("formatting_cues_disable")),
        }
        default_key = "1"
        while True:
            print(self.loc.t("formatting_cues_title"))
            for key, (_, label) in options.items():
                entry = f"{key}. {label}"
                if key == default_key:
                    entry = self.loc.highlight_default(entry + self.loc.t("default_suffix"))
                print(entry)
            try:
                choice = self.prompt.ask(
                    self.loc.t("select_formatting_cues_prompt"),
                    valid=options.keys(),
                    allow_blank_default=True,
                    default=default_key,
                    digits_only=True,
                )
            except EOFError:
                return None
            if choice is None or choice not in options:
                print(self.loc.t("invalid_option"))
                continue
            return options[choice][0]

    def _choose_engine(self) -> Optional[str]:
        engines = {
            "1": ("edge", self.loc.t("engine_option_edge")),
            "2": ("coqui", self.loc.t("engine_option_coqui")),
            "3": ("piper", self.loc.t("engine_option_piper")),
            "0": (None, self.loc.t("engine_option_exit")),
        }
        default_key = "1"

        while True:
            print(self.loc.t("choose_engine_title"))
            for key, (_, description) in engines.items():
                label = f"{key}. {description}"
                if key == default_key:
                    label = self.loc.highlight_default(label + self.loc.t("default_suffix"))
                print(label)

            try:
                choice = self.prompt.ask(
                    self.loc.t("select_engine_prompt"),
                    valid=engines.keys(),
                    allow_blank_default=True,
                    default=default_key,
                    digits_only=True,
                )
            except EOFError:
                return None

            if choice is None:
                print(self.loc.t("invalid_option"))
                continue

            engine = engines[choice][0]
            if engine is None:
                return None
            print(self.loc.t("engine_selected", option=engines[choice][1]))
            return engine

    def _choose_voice(self, engine: str) -> Optional[str]:
        if engine == "edge":
            return self._choose_edge_voice()
        if engine == "coqui":
            return self._choose_coqui_model()
        if engine == "piper":
            return self._choose_piper_model()
        return None

    def _choose_edge_voice(self) -> Optional[str]:
        voices = self.voice_provider.edge_voices
        default_voice_id = self.voice_provider.get_voice("edge")
        default_key = next(
            (key for key, (voice_id, _) in voices.items() if voice_id == default_voice_id),
            next(iter(voices.keys()), None),
        )

        while True:
            print(self.loc.t("voice_title"))
            for key, (_, description) in voices.items():
                label = f"{key}. {description}"
                if key == default_key:
                    label = self.loc.highlight_default(label + self.loc.t("default_suffix"))
                print(label)
            print(self.loc.highlight_default(self.loc.t("press_enter_keep_default")))

            try:
                choice = self.prompt.ask(
                    self.loc.t("select_voice_prompt"),
                    valid=voices.keys(),
                    allow_blank_default=True,
                    default=default_key,
                    digits_only=True,
                )
            except EOFError:
                return None

            if choice is None:
                print(self.loc.t("invalid_option"))
                continue

            print(self.loc.t("voice_selected", option=voices[choice][1]))
            return voices[choice][0]

    def _choose_coqui_model(self) -> Optional[str]:
        models = self.voice_provider.coqui_models
        default_key = next(iter(models.keys()), None)

        while True:
            print(self.loc.t("model_title"))
            for key, (_, name, desc, _) in models.items():
                label = f"{key}. {name} - {desc}"
                if key == default_key:
                    label = self.loc.highlight_default(label + self.loc.t("default_suffix"))
                print(label)
            print(self.loc.highlight_default(self.loc.t("press_enter_keep_default")))

            try:
                choice = self.prompt.ask(
                    self.loc.t("select_model_prompt"),
                    valid=models.keys(),
                    allow_blank_default=True,
                    default=default_key,
                    digits_only=True,
                )
            except EOFError:
                return None

            if choice is None:
                print(self.loc.t("invalid_option"))
                continue

            print(self.loc.t("model_selected", option=models[choice][1]))
            return models[choice][0]

    def _choose_piper_model(self) -> Optional[str]:
        print(self.loc.t("piper_models_title"))
        print(self.loc.t("piper_models_hint"))
        print(self.loc.highlight_default(self.loc.t("press_enter_keep_default")))
        try:
            self.prompt.ask(self.loc.t("piper_models_prompt"), allow_blank_default=True, default="")
        except EOFError:
            return None
        return None

    def _choose_footnote_mode(self) -> Optional[str]:
        options: Dict[str, Optional[str]] = {
            "1": "inline",
            "2": "chapter_end",
            "3": "skip",
            "0": None,
        }

        label_map = {
            "1": self.loc.t("footnote_option_inline"),
            "2": self.loc.t("footnote_option_chapter_end"),
            "3": self.loc.t("footnote_option_skip"),
            "0": self.loc.t("footnote_option_cancel"),
        }

        while True:
            print(self.loc.t("footnote_title"))
            for key in ["1", "2", "3", "0"]:
                label = f"{key}. {label_map[key]}"
                if key == "1":
                    label = self.loc.highlight_default(label + self.loc.t("default_suffix"))
                print(label)

            try:
                choice = self.prompt.ask(
                    self.loc.t("select_footnote_prompt"),
                    valid=options.keys(),
                    allow_blank_default=True,
                    default="1",
                    digits_only=True,
                )
            except EOFError:
                return None

            if choice is None:
                print(self.loc.t("invalid_option"))
                continue

            print(self.loc.t("footnote_selected", option=label_map.get(choice, choice)))
            return options[choice]


__all__ = ["MenuInterface"]
