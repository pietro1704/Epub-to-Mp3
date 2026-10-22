"""Verification for the retained legacy CLI."""

from . import cli_runtime_dependencies as _shared_cli_runtime_dependencies
from .cli_runtime_dependencies import ConversionConfig as ConversionConfig
from .cli_runtime_dependencies import Path as Path
from .cli_runtime_dependencies import traceback as traceback

asyncio = _shared_cli_runtime_dependencies.asyncio
os = _shared_cli_runtime_dependencies.os

class CLIVerification:
    def _run_verify_only(
        self, input_path: Path, config: ConversionConfig, interactive: bool = False
    ) -> int:
        """Validate existing output/cache against the source EPUB without synthesizing audio."""
        safe_name = self.converter.file_manager.sanitize_filename(config.book_title or "default")
        output_dir = self._cli_runtime.Path(config.output_dir) / safe_name
        cache_dir = self._cli_runtime.Path(config.cache_dir) if getattr(config, "cache_dir", None) else None

        if not output_dir.exists():
            print(f"❌ Output not found for validation: {output_dir}")
            print(f"   Expected output directory derived from book title: {output_dir}")
            print("   Run a conversion first, or pass --output-dir if you used a custom path.")
            return 1

        print("🔍 Verify mode: no new audio will be generated.")
        print(f"📁 Output: {output_dir}")
        if cache_dir:
            print(f"📁 Cache: {cache_dir}")
        try:
            from validate_conversion import validate_book

            _, issues = validate_book(input_path, output_dir=output_dir, cache_dir=cache_dir)
        except Exception as exc:
            print(f"❌ Validation failed: {exc}")
            return 1

        if issues:
            print(f"❌ Verification failed: {len(issues)} issue(s) found.")
            if interactive:
                print("\nIssues:")
                for issue in issues:
                    print(f"  • {issue}")
                # Default Y: most users want to fix the issues they just
                # saw — the legacy [y/N] forced an extra keypress for the
                # common case and the user reported that pressing `y`
                # didn't register on their terminal. Empty input now
                # confirms; only an explicit `n`/`no` cancels.
                # Use TerminalPrompt so that CR-only lines (^M, common in
                # tmux/SSH or after a tty.setcbreak() menu) are handled
                # correctly — plain input() leaves CR in the buffer.
                try:
                    from src.ui.prompt import TerminalPrompt as _TP

                    _tp = _TP()
                    _result = _tp._read("\n🔧 Do you want to fix the issues now? [Y/n] ")
                    raw = _result.text if not _result.eof else ""
                except Exception:
                    try:
                        raw = input("\n🔧 Do you want to fix the issues now? [Y/n] ")
                    except (EOFError, KeyboardInterrupt):
                        raw = ""
                answer = (raw or "").strip().rstrip("\r").lower()
                if answer in ("", "y", "yes", "s", "sim"):
                    return self._run_fix_mode(input_path, config)
            return 1
        print("✅ Verification completed with no issues.")
        return 0

    def _run_fix_mode(self, input_path: Path, config: ConversionConfig) -> int:
        """Verify then fix: rename bad files, then reconvert problematic chapters until 100% intact."""
        import asyncio
        import os

        safe_name = self.converter.file_manager.sanitize_filename(config.book_title or "default")
        output_dir = self._cli_runtime.Path(config.output_dir) / safe_name
        cache_dir = self._cli_runtime.Path(config.cache_dir) if getattr(config, "cache_dir", None) else None

        if not output_dir.exists():
            print(f"❌ Output not found: {output_dir}")
            print(f"   Expected output directory derived from book title: {output_dir}")
            print("   Run a conversion first, or pass --output-dir if you used a custom path.")
            return 1

        print("🔧 Fix mode: validating and fixing the conversion...")
        print(f"📁 Output: {output_dir}")
        if cache_dir:
            print(f"📁 Cache: {cache_dir}")

        fix_summary: list[str] = []

        # Step 1: Fix file naming issues (HTML in names, illegal characters)
        try:
            from validate_conversion import fix_output_filenames

            renamed = fix_output_filenames(output_dir, cache_dir=cache_dir)
            if renamed:
                print(f"\n✏️  Fixed {len(renamed)} filename(s) with HTML/invalid characters.")
                fix_summary.append(f"Renamed {len(renamed)} file(s) with bad names")
        except Exception as exc:
            print(f"⚠️  Filename fix skipped: {exc}")

        # Step 2: Validate
        try:
            from validate_conversion import validate_book

            _, issues = validate_book(input_path, output_dir=output_dir, cache_dir=cache_dir)
        except Exception as exc:
            print(f"❌ Validation failed: {exc}")
            return 1

        if not issues:
            if fix_summary:
                print("\n✅ Fix completed:")
                for item in fix_summary:
                    print(f"   • {item}")
            else:
                print("✅ No issues found — book is already 100% intact.")
            return 0

        issues_before = len(issues)
        print(f"\n🔧 {issues_before} issue(s) found. Starting reconversion loop...")

        # Step 3: Reconvert bad chapters until clean
        fix_config = config
        fix_config.auto_fix_output = False  # prevent re-entry
        fix_config.auto_validate_output = False
        self.converter._active_config = fix_config

        try:
            max_retries = int(os.getenv("MAX_VALIDATION_RETRIES", "8"))
            success = asyncio.run(
                self.converter._auto_validate_and_retry_async(
                    output_dir, input_path, cache_dir, max_retries=max_retries
                )
            )
        except Exception as exc:
            print(f"❌ Fix failed: {exc}")
            import traceback

            traceback.print_exc()
            return 1

        print("\n" + "=" * 60)
        print("🔧 FIX SUMMARY")
        print("=" * 60)
        for item in fix_summary:
            print(f"  • {item}")
        if success:
            print(f"  • Resolved {issues_before} validation issue(s) via reconversion")
            print("=" * 60)
            print("✅ Fix completed: book is 100% intact!")
            return 0
        else:
            print(f"  • Started with {issues_before} issue(s) — some may remain")
            print("=" * 60)
            print("⚠️  Fix completed with remaining issues. Run --verify to see details.")
            return 1
