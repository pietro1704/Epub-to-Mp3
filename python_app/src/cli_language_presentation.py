"""Language presentation for the retained legacy CLI."""

from .cli_runtime_dependencies import (
    ConversionConfig as ConversionConfig,
    EbookReader as EbookReader,
    Optional as Optional,
)

class CLILanguagePresentation:
    def _apply_language_preferences(self, config: ConversionConfig) -> None:
        profile = self.language_profile
        # UI language controls labels/formatting only. It must never select
        # the narration language for an EPUB whose detection is uncertain.
        fallback_lang = (
            config.primary_language
            if config.primary_language and config.primary_language not in {"auto", "unknown"}
            else "unknown"
        )
        if profile is None:
            profile = self._cli_runtime.LanguageProfile(
                primary=config.primary_language,
                languages=[config.primary_language],
                predictions=[],
                analysed_chars=0,
            )
        elif not profile.is_confident:
            profile = self._cli_runtime.LanguageProfile(
                primary=fallback_lang,
                languages=[fallback_lang],
                predictions=profile.predictions,
                analysed_chars=profile.analysed_chars,
            )

        languages = [lang for lang in profile.languages if lang and lang not in {"unknown", "auto"}]
        if not languages and profile.primary and profile.primary not in {"unknown", "auto"}:
            languages = [profile.primary]
        if not languages:
            languages = (
                [config.primary_language]
                if config.primary_language and config.primary_language != "auto"
                else []
            )

        primary_language = profile.primary if profile.primary not in {None, "", "unknown"} else None
        if not primary_language and languages:
            primary_language = languages[0]
        if not primary_language or primary_language in {"", "unknown"}:
            primary_language = (
                config.primary_language
                if config.primary_language not in {None, "", "auto"}
                else "auto"
            )

        config.primary_language = primary_language or "auto"
        config.languages = languages or (
            [config.primary_language] if config.primary_language not in {None, "auto"} else []
        )

        language_roots = {
            self._normalise_language_code(lang) for lang in (config.languages or []) if lang
        }
        language_roots.discard("")
        len(language_roots) == 1
        # Always prefer ThalitaMultilingualNeural — it is the highest quality
        # Edge voice for pt-BR and handles mixed-language text seamlessly.
        # Monolingual voices (Francisca, etc.) are only used when explicitly
        # requested via --voice.
        config.prefer_monolingual_edge = False

        voice_auto_raw = config.extra.get("voice_auto", False)

        def _to_bool(value) -> bool:
            if isinstance(value, bool):
                return value
            if value is None:
                return False
            text = str(value).strip().lower()
            if text in {"1", "true", "yes", "on"}:
                return True
            if text in {"0", "false", "no", "off"}:
                return False
            return bool(text)

        voice_auto = _to_bool(voice_auto_raw)
        if primary_language and (not config.voice or voice_auto):
            suggested_voice = self.config.voice_configs.get_voice(config.engine, primary_language)
            if suggested_voice:
                config.voice = suggested_voice
        if voice_auto and not config.voice:
            for lang in languages:
                suggested_voice = self.config.voice_configs.get_voice(config.engine, lang)
                if suggested_voice:
                    config.voice = suggested_voice
                    break

        prefer_piper = bool(
            language_roots == {"pt"}
            and profile.is_confident
            and self.config.voice_configs.has_piper_model(primary_language)
        )
        config.auto_prefer_piper = prefer_piper

        language_voice_map = self.config.voice_configs.build_language_voice_map(
            config.engine,
            config.languages
            or ([config.primary_language] if config.primary_language not in {None, "auto"} else []),
            config.voice,
            primary_language=config.primary_language,
        )

        config.language_voices = language_voice_map

        if not self._voice_supports_multilingual(config.engine, config.voice):
            if primary_language and primary_language not in {"", "unknown", "auto"}:
                config.languages = [primary_language]
            else:
                fallback = fallback_lang if fallback_lang not in {"", "unknown"} else None
                config.primary_language = fallback or "auto"
                config.languages = (
                    [config.primary_language] if config.primary_language not in {"", "auto"} else []
                )
            config.language_voices = {}

    @staticmethod
    def _voice_supports_multilingual(engine: Optional[str], voice: Optional[str]) -> bool:
        engine_name = (engine or "").lower()
        voice_name = (voice or "").lower()
        if not voice_name:
            return False
        if engine_name == "edge":
            return "multilingual" in voice_name
        if engine_name == "piper":
            return True
        return False

    def _display_ebook_metadata(self, reader: EbookReader) -> None:
        """Display ebook metadata at application startup."""
        print("=" * 60)
        print("📚 METADADOS DO EBOOK")
        print("=" * 60)

        # Basic metadata
        print(f"📜 Title: {reader.title or 'N/A'}")
        print(f"✍️ Autor: {reader.author or 'N/A'}")

        # Chapter count
        chapters = list(reader.get_chapters())
        print(f"📊 Chapters: {len(chapters)}")

        # Calculate total text statistics
        total_chars = sum(len(chapter.text or "") for chapter in chapters)
        total_words = sum(len((chapter.text or "").split()) for chapter in chapters)

        print(f"📝 Total de caracteres: {total_chars:,}")
        print(f"💬 Total de palavras: {total_words:,}")

        # File info
        if reader.file_path:
            file_size = reader.file_path.stat().st_size
            file_size_mb = file_size / (1024 * 1024)
            print(f"💾 File size: {file_size_mb:.1f} MB")
            print(f"🗺 Formato: {reader.file_path.suffix.upper()[1:]}")

        # TOC info
        try:
            toc_items = list(reader.get_toc())
            if toc_items:
                print(f"🗺 TOC: {len(toc_items)} entries")
        except Exception:
            pass

        print("=" * 60)
        print()

    def _update_metadata_display_language(self) -> None:
        """Update the terminal with language detection results."""
        if self.language_profile:
            print("🌐 LANGUAGE DETECTION")
            print("-" * 30)
            if self.language_profile.primary:
                confidence = "High" if self.language_profile.is_confident else "Low"
                print(
                    f"🌐 Primary language: {self.language_profile.primary} (confidence: {confidence})"
                )
                if len(self.language_profile.predictions) > 0:
                    best_prediction = self.language_profile.predictions[0]
                    print(f"   Accuracy: {best_prediction.probability:.1%}")
                if len(self.language_profile.languages) > 1:
                    other_langs = ", ".join(
                        self.language_profile.languages[1:3]
                    )  # Show up to 2 more
                    print(f"🌍 Secondary languages: {other_langs}")
            print(f"🔍 Caracteres analisados: {self.language_profile.analysed_chars:,}")
            print()

    def _announce_footnote_mode(self, config: ConversionConfig) -> None:
        """Display the chosen footnote handling mode once per run."""
        if self._footnote_summary_printed:
            return

        mode = (getattr(config, "footnote_mode", "inline") or "inline").lower()
        raw_context = getattr(config, "footnote_context_words", self.FOOTNOTE_CONTEXT_WORDS)
        try:
            context_words = max(int(raw_context), 0)
        except (TypeError, ValueError):
            context_words = self.FOOTNOTE_CONTEXT_WORDS
        if context_words == 0:
            context_words = self.FOOTNOTE_CONTEXT_WORDS

        label_keys = {
            "inline": "footnote_option_inline",
            "chapter_end": "footnote_option_chapter_end",
            "skip": "footnote_option_skip",
        }
        label_key = label_keys.get(mode, "footnote_option_inline")
        mode_label = self.localization.t(label_key)
        print(self.localization.t("footnote_selected", option=mode_label))

        if mode == "inline":
            print(self.localization.t("footnote_inline_context", value=context_words))
        elif mode == "chapter_end":
            print(self.localization.t("footnote_chapter_end_context", value=context_words))

        self._footnote_summary_printed = True
