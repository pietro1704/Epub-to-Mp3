"""Conversion completion for the retained legacy CLI."""

class CLIConversionCompletion:
    def _finish_cli_conversion(self, args, reader, structure_items, config, result, elapsed, conversion_start, temp_dir):

        # Log persistent conversion session record
        try:
            import json as _json
            from datetime import datetime, timezone

            from src.session_logger import log_session

            _converted = (
                result.converted_chapters if isinstance(result, self._cli_runtime.ConversionResult) else 0
            )
            _total = (
                result.total_chapters
                if isinstance(result, self._cli_runtime.ConversionResult)
                else len(structure_items)
            )
            _failed = _total - _converted
            _success = (
                result.success
                if isinstance(result, self._cli_runtime.ConversionResult)
                else (isinstance(result, int) and result == 0)
            )
            _outcome = "success" if _success else ("partial" if _converted > 0 else "failed")

            # Read per-chapter details from runtime metrics file
            _chapter_details: list = []
            _output_dir = getattr(config, "output_dir", None)
            if _output_dir:
                _metrics_path = self._cli_runtime.Path(_output_dir) / "_runtime_metrics.jsonl"
                if _metrics_path.exists():
                    try:
                        with open(_metrics_path, encoding="utf-8") as _mf:
                            for _line in _mf:
                                _line = _line.strip()
                                if not _line:
                                    continue
                                _ev = _json.loads(_line)
                                if _ev.get("event") == "chapter_complete":
                                    _detail = {
                                        "index": _ev.get("chapter"),
                                        "engine": _ev.get("engine", ""),
                                        "chars": _ev.get("chars"),
                                        "elapsedSeconds": round(
                                            float(_ev.get("elapsed_s") or 0), 1
                                        ),
                                        "status": "completed"
                                        if _ev.get("success")
                                        else "failed",
                                        "retryCount": max(0, int(_ev.get("attempt", 1)) - 1),
                                    }
                                    if _ev.get("error"):
                                        _detail["error"] = _ev["error"]
                                    _chapter_details.append(_detail)
                    except Exception:
                        pass

            # Surface *why* an otherwise-complete run ended up "partial"
            # (e.g. final cross-validation caught a duration/text
            # mismatch after every chapter loop-reported success) —
            # without this, outcome=partial + chapters_failed=0 is
            # unexplainable from the log alone.
            _result_errors = result.errors if isinstance(result, self._cli_runtime.ConversionResult) else None
            _log_extra: dict = {}
            if _result_errors:
                _log_extra["errors"] = list(_result_errors)[:20]

            log_session(
                book_title=reader.title or self._cli_runtime.Path(args.input_file).stem,
                book_author=getattr(reader, "author", "") or "",
                language=getattr(self.language_profile, "primary", "")
                if self.language_profile
                else "",
                engine=getattr(config, "engine", ""),
                voice=getattr(config, "voice", ""),
                chapters_total=_total,
                chapters_converted=_converted,
                chapters_failed=_failed,
                duration_seconds=elapsed,
                outcome=_outcome,
                output_dir=str(_output_dir or ""),
                started_at=datetime.fromtimestamp(
                    conversion_start, tz=timezone.utc
                ).isoformat(),
                chapter_details=_chapter_details or None,
                extra=_log_extra or None,
            )
        except Exception:
            pass  # Never let logging break a conversion
        if getattr(args, "show_metrics_summary", False):
            self._print_metrics_summary(temp_dir)
        if getattr(args, "show_metrics_dashboard", False):
            self._print_metrics_dashboard_path(temp_dir)
        if getattr(args, "open_metrics_dashboard", False):
            self._open_metrics_dashboard(temp_dir)
        if getattr(args, "export_metrics_bundle", False):
            self._export_metrics_bundle(temp_dir)

        # iPhone export (opt-in): copy the finished audiobook into
        # the MP3AudioBookPlayer iCloud Drive container so it
        # syncs to the device. Done last so a failed export never
        # affects the conversion exit code — the audio is on disk
        # regardless. macOS-only.
        cli_flag = getattr(args, "export_to_iphone", None)
        if cli_flag is None:
            from src.iphone_export import parse_env_flag

            want_export = parse_env_flag(self._cli_runtime.os.environ.get("EXPORT_TO_IPHONE"))
        else:
            want_export = bool(cli_flag)
        if want_export and isinstance(result, self._cli_runtime.ConversionResult) and result.success:
            from src.iphone_export import export_book_to_iphone, is_macos

            if not is_macos():
                print(
                    "⚠️  --export-to-iphone is macOS-only (iCloud Drive "
                    "container path); skipping export."
                )
            else:
                # `_output_dir` is the *root* output directory (e.g.
                # `output/`); MP3s live in `<root>/<sanitised title>/`.
                # Use the same sanitiser the converter used so we
                # land on the correct sub-folder instead of an empty
                # parent (the v0.3.20 fix).
                book_title_for_export = (
                    getattr(reader, "title", "") or self._cli_runtime.Path(args.input_file).stem
                )
                output_dir_for_export = None
                if _output_dir:
                    safe_book_dir = self._cli_runtime.FileManager.sanitize_filename(
                        book_title_for_export or "default"
                    )
                    output_dir_for_export = self._cli_runtime.Path(_output_dir) / safe_book_dir
                if output_dir_for_export:
                    ok, error = export_book_to_iphone(
                        output_dir_for_export,
                        book_title=book_title_for_export,
                        log=print,
                    )
                    if not ok:
                        print(f"⚠️  iPhone export skipped: {error}")

        # Post-conversion budget sweep: newly written MP3s may push
        # combined size over the limit; evict oldest entries now so the
        # next CLI session starts clean.
        try:
            from src.storage_budget import evict_storage_budget

            _active_book_dir = (
                self._cli_runtime.Path(getattr(config, "output_dir", None) or self._cli_runtime.OUTPUT_DIR)
                if config is not None
                else None
            )
            evict_storage_budget(
                self.cache_root,
                self._cli_runtime.OUTPUT_DIR,
                active_book_dirs=[_active_book_dir] if _active_book_dir else [],
            )
        except Exception:
            pass
