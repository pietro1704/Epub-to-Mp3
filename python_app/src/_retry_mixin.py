# -*- coding: utf-8 -*-
"""Retry logic, failure tracking and deferred recovery helpers for AudioConverter."""

from __future__ import annotations

import asyncio
import os
import re
from pathlib import Path
from typing import List, Optional, Set

from .ebook_reader import Chapter
from .failure_checkpoint_store import FailureCheckpointStore
from .last_resort_recovery import LastResortRecovery


class _RetryMixin(FailureCheckpointStore, LastResortRecovery):
    @staticmethod
    def _scaled_quick_timeout(base_seconds: int, chars: int, engine: str) -> int:
        """Scale a quick-synthesis timeout to the chapter's size.

        A chapter that already failed once tends to be slow, and the fixed
        defaults (90s Edge / 360s Piper) were sized around a ~15k-char chapter.
        For larger chapters we grow the budget proportionally so the retry
        isn't starved by a too-tight timeout.
        """
        base = max(10, int(base_seconds))
        chars = max(0, int(chars))
        if chars <= 0:
            return base
        ref_chars = {"edge": 15000, "piper": 8000}.get(engine.lower(), 12000)
        if chars <= ref_chars:
            return base
        overflow = (chars - ref_chars) / float(ref_chars)
        scale = min(3.0, 1.0 + overflow * 1.3)
        return int(base * scale)

    @staticmethod
    def _classify_failure_reason(error_text: Optional[str]) -> str:
        text = str(error_text or "").strip().lower()
        if not text:
            return "unknown"
        if any(token in text for token in ("unauthorized", "forbidden", "401", "403", "auth")):
            return "auth"
        if any(
            token in text
            for token in (
                "rate_limit",
                "rate limit",
                "too many requests",
                "429",
                "throttle",
                "quota",
            )
        ):
            return "throttle"
        if any(token in text for token in ("noaudio", "no_audio", "noaudioreceived")):
            return "no_audio"
        if any(
            token in text
            for token in ("ssl", "certificate", "dns", "connector", "connection refused")
        ):
            return "network"
        if any(token in text for token in ("timeout", "timed out", "503", "service_unavailable")):
            return "transient"
        if "connection" in text:
            return "network"
        return "unknown"


    async def _reconvert_missing_mp3s(
        self, output_dir: Path, cache_dir: Optional[Path], chapter_nums: list, issues: list
    ) -> bool:
        """
        Reconvert only the missing MP3s using cached text.

        Returns:
            True if all MP3s were generated successfully
        """
        if not cache_dir or not cache_dir.exists():
            return False

        try:
            from .config import VoiceConfigProvider
            from .tts.factory import TTSFactory
            from .utils import AudioProcessor

            config = self._active_config
            if not config:
                return False

            original_primary_language = getattr(config, "primary_language", None)
            original_languages = list(getattr(config, "languages", []) or [])
            effective_lang = self._effective_primary_language(config)
            config.primary_language = effective_lang
            if not original_languages:
                config.languages = [effective_lang]

            factory = TTSFactory()
            available_engines = set(factory.available_engines())

            requested_engine = (getattr(config, "engine", "") or "edge").lower()
            # Respect ``--fallback-engine none``: when the operator
            # explicitly disabled fallback, the retry pass must NOT
            # widen the candidate list past the requested engine. Skips
            # the "edge → piper for short chapters" silent route that
            # produced wrong-language audio for Carl's Capa chapter.
            cli_fallback = (getattr(self, "_cli_fallback_engine", None) or "").lower()
            ordered_candidates: list[str] = []

            def _append_candidate(engine_name: str) -> None:
                if not engine_name:
                    return
                if engine_name in ordered_candidates:
                    return
                ordered_candidates.append(engine_name)

            if cli_fallback == "none":
                # Strict mode: only the engine the user picked.
                _append_candidate(requested_engine if requested_engine != "auto" else "edge")
            elif cli_fallback == "piper":
                # Operator pinned a specific fallback tier.
                _append_candidate(requested_engine if requested_engine != "auto" else "edge")
                _append_candidate(cli_fallback)
            elif requested_engine == "auto":
                _append_candidate("edge")
                _append_candidate("piper")
            else:
                _append_candidate(requested_engine)
                if requested_engine == "edge":
                    _append_candidate("piper")
                elif requested_engine == "piper":
                    _append_candidate("edge")

            engine_candidates = [
                name for name in ordered_candidates if name == "edge" or name in available_engines
            ]
            if not engine_candidates:
                if self.verbose:
                    print(
                        f"⚠️  Error while reconverting MP3s: no available engine for request '{requested_engine}'"
                    )
                return False

            selected_engine_name = ""
            tts_engine = None
            original_engine = config.engine
            engine_errors: list[str] = []
            for candidate in engine_candidates:
                try:
                    config.engine = candidate
                    tts_engine = factory.create_engine(config)
                    selected_engine_name = candidate
                    break
                except Exception as exc:
                    engine_errors.append(f"{candidate}: {exc}")
                    continue
                finally:
                    config.engine = original_engine

            if not tts_engine:
                if self.verbose:
                    detail = "; ".join(engine_errors[:3]) if engine_errors else "unknown reason"
                    print(f"⚠️  Error while reconverting MP3s: {detail}")
                return False

            if self.verbose and selected_engine_name != requested_engine:
                print(
                    f"   🔄 Quick synthesis engine fallback: {requested_engine} → {selected_engine_name}"
                )

            # Create audio processor
            audio_processor = AudioProcessor()
            piper_engine = None
            edge_quick_timeout = max(20, int(os.getenv("EDGE_QUICK_SYNTH_TIMEOUT", "90") or "90"))
            piper_quick_timeout = max(
                60, int(os.getenv("PIPER_QUICK_SYNTH_TIMEOUT", "360") or "360")
            )
            generic_quick_timeout = max(
                45, int(os.getenv("GENERIC_QUICK_SYNTH_TIMEOUT", "240") or "240")
            )
            quick_synth_max_chars = max(
                5000, int(os.getenv("QUICK_SYNTH_MAX_CHARS", "300000") or "300000")
            )

            def _is_edge_network_failure(exc: BaseException) -> bool:
                text = str(exc or "").lower()
                return any(
                    token in text
                    for token in (
                        "clientconnectordnserror",
                        "persistent ssl error",
                        "cannot connect to host",
                        "speech.platform.bing.com",
                        "dns",
                        "ssl",
                        "timeout",
                    )
                )

            normalized_targets: List[str] = []
            seen_targets: Set[str] = set()
            for raw in chapter_nums:
                key = str(raw).strip()
                if not key or key in seen_targets:
                    continue
                seen_targets.add(key)
                normalized_targets.append(key)

            success_count = 0
            completed_targets: Set[str] = set()

            for chapter_num in normalized_targets:
                try:
                    issue_heading = None
                    chapter_token = str(chapter_num).strip()
                    for issue in issues or []:
                        issue_text = str(issue)
                        if f"Chapter {chapter_token} '" not in issue_text:
                            continue
                        try:
                            issue_heading = issue_text.split(f"Chapter {chapter_token} '", 1)[
                                1
                            ].split("':", 1)[0]
                            break
                        except Exception:
                            continue

                    text_dirs: List[Path] = []
                    for candidate in (
                        cache_dir / "text",
                        cache_dir,
                        output_dir / "text",
                    ):
                        if candidate.exists() and candidate.is_dir():
                            text_dirs.append(candidate)
                    if not text_dirs:
                        if self.verbose:
                            print(f"   ⚠️  Chapter {chapter_num}: no text cache directories found")
                        continue

                    target_file, using_parsed_fallback, pre_tts_map = (
                        self._find_quick_synth_text_file(
                            chapter_num=chapter_token,
                            text_dirs=text_dirs,
                            issue_heading=issue_heading,
                        )
                    )

                    if not target_file or not target_file.exists():
                        if self.verbose:
                            print(f"   ⚠️  Chapter {chapter_num}: pre-tts.txt not found")
                            sample_files: List[str] = []
                            for files in pre_tts_map.values():
                                sample_files.extend([f.name[:50] for f in files[:2]])
                            print(f"      Available files: {sample_files[:6]}")
                        continue

                    # Read text
                    text = target_file.read_text(encoding="utf-8")
                    if not text:
                        if self.verbose:
                            print(f"   ⚠️  Chapter {chapter_num}: empty text")
                        continue
                    if len(text) > quick_synth_max_chars:
                        if self.verbose:
                            print(
                                f"   ⚠️  Chapter {chapter_num}: text too large for quick synthesis "
                                f"({len(text):,} chars > {quick_synth_max_chars:,}) - forcing full reconversion"
                            )
                        continue

                    # Extract chapter name from filename
                    chapter_name = target_file.stem.replace("-pre-tts", "").replace("-parsed", "")
                    # If file has sequential prefix ("9 - 4.3 - ..."), strip it to keep MP3 naming aligned.
                    chapter_name = re.sub(
                        r"^\s*\d+\s*-\s*(?=\d+(?:\.\d+)?\s*-)",
                        "",
                        chapter_name,
                    ).strip()
                    if issue_heading:
                        # Use EPUB heading from validator when available to preserve TOC order/name.
                        chapter_name = issue_heading.strip()

                    if self.verbose:
                        source_tag = "parsed fallback" if using_parsed_fallback else "pre-tts"
                        print(f"   🎙️  Chapter {chapter_num}: synthesizing MP3 ({source_tag})...")

                    # Synthesize audio
                    wav_file = None
                    chapter_chars = len(text)
                    try:
                        synth_task = tts_engine.synthesize_async(
                            text, target_file.parent / f"temp_{chapter_num}.wav"
                        )
                        if selected_engine_name == "edge":
                            timeout_s = self._scaled_quick_timeout(
                                edge_quick_timeout, chapter_chars, "edge"
                            )
                        elif selected_engine_name == "piper":
                            timeout_s = self._scaled_quick_timeout(
                                piper_quick_timeout, chapter_chars, "piper"
                            )
                        else:
                            timeout_s = self._scaled_quick_timeout(
                                generic_quick_timeout, chapter_chars, selected_engine_name or ""
                            )
                        wav_file = await asyncio.wait_for(synth_task, timeout=timeout_s)
                    except Exception as primary_exc:
                        # Carl regression guard: with `--fallback-engine
                        # none` the operator explicitly forbids piper.
                        # Don't let the inner retry loop silently switch
                        # to piper (which would synthesise pt-BR audio
                        # in 16 kHz English-trained Piper voice).
                        cli_fallback = (getattr(self, "_cli_fallback_engine", None) or "").lower()
                        piper_allowed = cli_fallback != "none"
                        if (
                            selected_engine_name == "edge"
                            and piper_allowed
                            and "piper" in available_engines
                        ):
                            try:
                                if piper_engine is None:
                                    piper_language = self._effective_primary_language(config)
                                    piper_model = VoiceConfigProvider().get_voice(
                                        "piper", piper_language
                                    )
                                    config.engine = "piper"
                                    config.primary_language = piper_language
                                    if piper_model:
                                        config.model_path = Path(piper_model)
                                    piper_engine = factory.create_engine(config)
                                    if self.verbose:
                                        reason = (
                                            "network/timeout"
                                            if _is_edge_network_failure(primary_exc)
                                            else "error"
                                        )
                                        print(
                                            f"   🔄 Edge quick synthesis failed ({reason}); retrying chapter with Piper"
                                        )
                                piper_task = piper_engine.synthesize_async(
                                    text, target_file.parent / f"temp_{chapter_num}.wav"
                                )
                                wav_file = await asyncio.wait_for(
                                    piper_task,
                                    timeout=self._scaled_quick_timeout(
                                        piper_quick_timeout, chapter_chars, "piper"
                                    ),
                                )
                            except Exception as fallback_exc:
                                if self.verbose:
                                    print(
                                        f"   ⚠️  Chapter {chapter_num}: edge and piper failed - {fallback_exc}"
                                    )
                                wav_file = None
                            finally:
                                config.engine = original_engine
                        else:
                            if self.verbose and isinstance(primary_exc, asyncio.TimeoutError):
                                print(
                                    f"   ⚠️  Chapter {chapter_num}: quick synthesis timeout on {selected_engine_name}"
                                )
                            raise

                    if not wav_file or not Path(wav_file).exists():
                        if self.verbose:
                            print(f"   ❌ Chapter {chapter_num}: synthesis failed")
                        continue

                    # Convert to MP3
                    mp3_path = output_dir / f"{chapter_name}.mp3"
                    await audio_processor.convert_to_mp3(Path(wav_file), mp3_path)

                    # Clean up temporary WAV
                    Path(wav_file).unlink(missing_ok=True)

                    if mp3_path.exists():
                        success_count += 1
                        completed_targets.add(str(chapter_num).strip())
                        if self.verbose:
                            print(f"   ✅ Chapter {chapter_num}: MP3 generated")
                    else:
                        if self.verbose:
                            print(f"   ❌ Chapter {chapter_num}: MP3 conversion failed")

                except Exception as exc:
                    if self.verbose:
                        print(f"   ⚠️  Chapter {chapter_num}: error - {exc}")
                    continue

            all_done = len(completed_targets) == len(normalized_targets)
            if self.verbose:
                print(
                    f"   📈 Quick synthesis result: {len(completed_targets)}/{len(normalized_targets)} chapter(s)"
                )
            return all_done

        except Exception as exc:
            if self.verbose:
                print(f"⚠️  Error while reconverting MP3s: {exc}")
            return False
        finally:
            if config:
                config.primary_language = original_primary_language
                config.languages = original_languages


    def _resolve_problem_chapter_indices(
        self, chapters: List[Chapter], selectors: List[str]
    ) -> List[str]:
        """
        Resolve selectors from validation issues to actual chapter.index labels.
        Supports decimal labels (e.g. 4.2, 5.0), EPUB position, and sequential non-empty index.
        """
        if not chapters or not selectors:
            return []

        wanted: Set[str] = set()
        for selector in selectors:
            wanted.update(self._chapter_selector_aliases(selector))
        if not wanted:
            return []

        from validate_conversion import normalize_text

        chapter_indices: List[str] = []
        seen_indices: Set[str] = set()
        sequential_num = 0
        for epub_idx, chapter in enumerate(chapters, 1):
            text = chapter.text or ""
            if not text or not normalize_text(text):
                continue
            sequential_num += 1

            label = self._chapter_index_label(chapter, sequential_num)
            chapter_aliases: Set[str] = set()
            chapter_aliases.update(self._chapter_selector_aliases(label))
            chapter_aliases.update(self._chapter_selector_aliases(epub_idx))
            chapter_aliases.update(self._chapter_selector_aliases(sequential_num))

            # Avoid matching decimal chapters (e.g. 4.2) via integer fallback (4).
            if "." not in label:
                chapter_aliases.update(
                    self._chapter_selector_aliases(self._chapter_number(chapter, sequential_num))
                )

            if wanted.intersection(chapter_aliases):
                idx = str(getattr(chapter, "index", sequential_num))
                if idx not in seen_indices:
                    chapter_indices.append(idx)
                    seen_indices.add(idx)

        return chapter_indices

    @staticmethod
    def _should_flag_slowdown(error_msg: Optional[str]) -> bool:
        """Check if error indicates slowdown condition."""
        if not error_msg:
            return False
        try:
            error_lower = str(error_msg).lower()
        except Exception:
            return False
        return any(
            keyword in error_lower for keyword in ["timeout", "rate", "limit", "throttle", "quota"]
        )
