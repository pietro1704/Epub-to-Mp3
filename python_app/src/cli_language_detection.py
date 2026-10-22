"""Language detection for the retained legacy CLI."""

from .cli_runtime_dependencies import (
    ChapterStructureItem as ChapterStructureItem,
    ConversionConfig as ConversionConfig,
    EbookReader as EbookReader,
    LanguageProfile as LanguageProfile,
    List as List,
    Optional as Optional,
)

class CLILanguageDetection:
    def _preflight_language_and_config_check(
        self,
        reader: EbookReader,
        items: List[ChapterStructureItem],
        config: ConversionConfig,
        args,
    ) -> bool:
        """Second-pass verification before TTS starts.

        The Carl regression (v0.3.20→v0.3.21) shipped pt-BR audiobook
        narrated by an English Piper model. The first-pass detection
        had agreed on pt-BR; the bug was downstream. But "two
        independent confirmations are better than one" — running a
        second detection over a *different* sample window catches the
        case where the first sample was unrepresentative (e.g. a book
        whose first 5 chapters are all front-matter in English while
        the body is Portuguese).

        Also surfaces the final engine + voice + fallback decisions so
        the user can spot a misconfigured run BEFORE 10 minutes of
        synthesis. Honours `--language` override (the user's choice
        wins, we only warn). Returns True to proceed, False to abort.
        """

        primary = (config.primary_language or "").lower()
        primary_root = primary.split("-", 1)[0]
        user_language_override = bool(
            self._normalize_language_override(getattr(args, "language", None))
        )

        # Independent re-detection over a different sample window:
        # take chapters from the *middle* of the book, not the priority
        # positions used by `_prepare_language_profile`. Mid-book is
        # almost always main content, free of front-matter noise.
        sample_texts: List[str] = []
        total_chars = 0
        if items:
            mid_start = max(0, len(items) // 4)
            mid_end = min(len(items), max(mid_start + 5, (3 * len(items)) // 4))
            for item in items[mid_start:mid_end]:
                source_text = (
                    item.text_override
                    if item.text_override is not None
                    else getattr(item.chapter, "text", "")
                )
                if not source_text and getattr(item.chapter, "raw_html", None):
                    source_text = self._cli_runtime.TextProcessor.html_to_plain_text(item.chapter.raw_html)
                if source_text and len(source_text.strip()) > 200:
                    sample_texts.append(source_text)
                    total_chars += len(source_text)
                    if total_chars >= 5000:
                        break

        verified_lang = ""
        if sample_texts:
            try:
                second_profile = self.language_detector.detect_profile(sample_texts)
                if second_profile and second_profile.primary:
                    verified_lang = second_profile.primary.lower()
            except Exception:
                verified_lang = ""

        verified_root = verified_lang.split("-", 1)[0] if verified_lang else ""

        print()
        print("🔎 Pre-flight check (idioma + parâmetros)")
        print(f"   • Idioma detectado (1ª passagem): {primary or '?'}")
        if verified_lang:
            match = "✓ Match" if verified_root == primary_root else "✗ MISMATCH"
            print(
                f"   • Idioma detectado (2ª passagem, amostra independente): {verified_lang}  {match}"
            )
        else:
            print("   • Idioma detectado (2ª passagem): inconclusivo (texto insuficiente)")
        engine_choice = getattr(args, "engine", "auto") or "auto"
        fallback_choice = getattr(args, "fallback_engine", "auto") or "auto"
        print(f"   • Engine pedido pelo usuário: {engine_choice}")
        print(f"   • Fallback engine: {fallback_choice}")
        if config.voice:
            print(f"   • Voice: {config.voice}")

        if verified_root and primary_root and verified_root != primary_root:
            if user_language_override:
                print(
                    f"   ⚠️  Override do usuário (--language={primary}) difere da 2ª detecção "
                    f"({verified_lang}). Respeitando o pedido do usuário."
                )
            else:
                print()
                print(
                    f"❌ Discrepância de idioma: 1ª passagem disse '{primary}', "
                    f"2ª passagem (amostra independente) disse '{verified_lang}'."
                )
                print(
                    "   Conversão abortada para não gerar áudio em idioma errado. "
                    f"Force com --language {primary} ou --language {verified_lang}."
                )
                return False

        return True

    def _prepare_language_profile(
        self,
        reader: EbookReader,
        items: List[ChapterStructureItem],
        verbose: bool = False,
        *,
        allow_prompt: bool = True,
    ) -> LanguageProfile:
        print(self.localization.t("language_profile_start"), flush=True)
        sample_texts: List[str] = []

        # **FIXED**: Improve language detection for books with empty/short chapters
        # Collect text until we have at least 2000 chars or 20 chapters
        total_chars = 0
        items_checked = 0
        max_items = min(20, len(items))  # Up to 20 chapters
        # IMPROVED: Increased minimum chars for more confident detection (was 2000)
        # This ensures we have enough text to reliably detect the book's primary language
        min_chars = 5000  # Minimum 5000 chars for more reliable detection
        min_chapters = 5  # Minimum 5 chapters (was 3)

        total_items = len(items)
        if total_items <= max_items:
            sample_positions = list(range(total_items))
        else:
            sample_positions = sorted(
                {round(i * (total_items - 1) / (max_items - 1)) for i in range(max_items)}
            )

        for pos in sample_positions:
            if pos >= len(items):
                continue
            item = items[pos]
            source_text = (
                item.text_override
                if item.text_override is not None
                else getattr(item.chapter, "text", "")
            )
            if not source_text and getattr(item.chapter, "raw_html", None):
                source_text = self._cli_runtime.TextProcessor.html_to_plain_text(item.chapter.raw_html)
            if source_text and len(source_text.strip()) > 10:  # Ignorar textos muito pequenos
                sample_texts.append(source_text)
                total_chars += len(source_text)
                items_checked += 1

                # Stop if we already have enough characters AND enough chapters
                if total_chars >= min_chars and items_checked >= min_chapters:
                    break

        if verbose:
            print(
                f"🔍 [VERBOSE] Language: analysed {items_checked} chapter(s), {total_chars} chars"
            )

        ascii_ratio = self._ascii_ratio(sample_texts)
        language_votes = self._collect_language_votes(sample_texts)
        profile = self.language_detector.detect_profile(sample_texts)
        profile = self._rebalance_language_profile(profile, ascii_ratio, language_votes)
        if profile.primary == "pt":
            profile = self._cli_runtime.LanguageProfile(
                primary="pt-BR",
                languages=[
                    "pt-BR" if self._normalise_lang_code(lang) == "pt" else lang
                    for lang in profile.languages
                ],
                predictions=profile.predictions,
                analysed_chars=profile.analysed_chars,
            )

        # Always show detected language
        print(
            f"🌍 Idioma detectado: {profile.primary or '?'} "
            f"({items_checked} capítulos, {total_chars} chars analisados)"
        )

        if not profile.languages or not profile.primary:
            if not allow_prompt:
                return self._cli_runtime.LanguageProfile(
                    primary=None,
                    languages=[],
                    predictions=profile.predictions or [],
                    analysed_chars=sum(len(text) for text in sample_texts),
                )
            languages = self._prompt_for_languages(reader)
            primary = languages[0] if languages else None
            return self._cli_runtime.LanguageProfile(
                primary=primary,
                languages=languages,
                predictions=[],
                analysed_chars=sum(len(text) for text in sample_texts),
            )

        return profile

    @staticmethod
    def _ascii_ratio(texts: List[str]) -> float:
        joined = " ".join(texts)
        if not joined:
            return 0.0
        ascii_chars = sum(1 for ch in joined if 32 <= ord(ch) <= 126)
        return ascii_chars / max(len(joined), 1)

    def _collect_language_votes(self, sample_texts: List[str]) -> dict[str, float]:
        votes: dict[str, float] = {}
        detector = self.language_detector
        for sample in sample_texts:
            if not sample or len(sample.strip()) < 20:
                continue
            local_profile = detector.detect_profile([sample])
            if not local_profile.predictions:
                continue
            weight = len(sample)
            for prediction in local_profile.predictions:
                code = self._cli_runtime.ConverterApplication._normalise_lang_code(prediction.code)
                if not code:
                    continue
                votes[code] = votes.get(code, 0.0) + (prediction.probability * weight)
        return votes

    @staticmethod
    def _normalise_lang_code(code: Optional[str]) -> str:
        if not code:
            return ""
        return code.split("-", 1)[0].lower()

    def _rebalance_language_profile(
        self,
        profile: LanguageProfile,
        ascii_ratio: float,
        language_votes: dict[str, float],
    ) -> LanguageProfile:
        if not profile.predictions:
            return profile

        top_prediction = profile.predictions[0]
        top_code = self._normalise_lang_code(top_prediction.code)
        en_prediction = next(
            (pred for pred in profile.predictions if self._normalise_lang_code(pred.code) == "en"),
            None,
        )

        if (
            en_prediction
            and top_code != "en"
            and ascii_ratio >= 0.65
            and (top_prediction.probability - en_prediction.probability) <= 0.22
        ):
            languages = ["en"] + [
                lang for lang in profile.languages if self._normalise_lang_code(lang) != "en"
            ]
            return self._cli_runtime.LanguageProfile(
                primary="en",
                languages=languages,
                predictions=profile.predictions,
                analysed_chars=profile.analysed_chars,
            )
        total_votes = sum(language_votes.values())
        if total_votes > 0:
            best_code, best_votes = max(language_votes.items(), key=lambda item: item[1])
            vote_ratio = best_votes / total_votes
            normalized_primary = self._normalise_lang_code(profile.primary)
            if vote_ratio >= 0.55 and best_code and normalized_primary != best_code:
                languages = [best_code] + [
                    lang
                    for lang in profile.languages
                    if self._normalise_lang_code(lang) != best_code
                ]
                return self._cli_runtime.LanguageProfile(
                    primary=best_code,
                    languages=languages,
                    predictions=profile.predictions,
                    analysed_chars=profile.analysed_chars,
                )
        return profile

    def _prompt_for_languages(self, reader: EbookReader) -> List[str]:
        default_language = self._infer_language_from_metadata(reader)
        fallback_language = default_language or (
            "pt" if self.localization.language == "pt" else "en"
        )

        if not self._interactive_mode or not self._cli_runtime.sys.stdin.isatty():
            return [fallback_language]

        try:
            raw = input(self.localization.t("language_prompt", default=fallback_language))
        except EOFError:
            return [fallback_language]

        if not raw.strip():
            return [fallback_language]

        languages = [self._normalise_language_code(part) for part in raw.split(",")]
        languages = [lang for lang in languages if lang]
        if not languages:
            languages = [fallback_language]
        return languages

    def _infer_language_from_metadata(self, reader: EbookReader) -> Optional[str]:
        title = (reader.title or "").lower()
        if any(token in title for token in ("portug", "brasil", "brasile")):
            return "pt"
        if any(token in title for token in ("english", "angl", "ingl")):
            return "en"
        return None

    @staticmethod
    def _normalise_language_code(raw: str) -> str:
        if not raw:
            return ""
        clean = raw.strip().lower()
        if not clean:
            return ""
        return clean.split("-", 1)[0]
