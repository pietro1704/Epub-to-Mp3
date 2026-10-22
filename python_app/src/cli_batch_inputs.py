"""Batch inputs for the retained legacy CLI."""

from .cli_runtime_dependencies import (
    List as List,
    Optional as Optional,
    Path as Path,
    Set as Set,
    Tuple as Tuple,
    argparse as argparse,
)

class CLIBatchInputs:
    def _resolve_batch_targets(self, args: argparse.Namespace) -> Tuple[List[Path], bool]:
        """Resolve positional + batch inputs into a deduplicated ordered list of books."""
        requested_batch = any(
            bool(getattr(args, attr, None))
            for attr in ("extra_inputs", "batch_inputs", "batch_manifest")
        )
        sources: List[str] = []
        positional: List[str] = []
        primary = getattr(args, "input_file", None)
        if primary:
            positional.append(str(primary))
        positional.extend(getattr(args, "extra_inputs", None) or [])
        sources.extend(positional)

        batch_inputs = getattr(args, "batch_inputs", None) or []
        sources.extend(batch_inputs)
        sources.extend(self._read_batch_manifest(getattr(args, "batch_manifest", None)))

        targets: List[Path] = []
        seen: Set[str] = set()
        for raw in sources:
            for expanded in self._expand_batch_source(raw):
                for file_path in self._flatten_source_to_files(expanded):
                    key = self._canonical_path_key(file_path)
                    if key in seen:
                        continue
                    seen.add(key)
                    targets.append(file_path)
        return targets, requested_batch

    def _expand_batch_source(self, raw: str) -> List[Path]:
        """Expand globs/user paths into concrete Path objects."""
        pattern = self._cli_runtime.os.path.expanduser(raw)
        matches = [self._cli_runtime.Path(match) for match in self._cli_runtime.glob.glob(pattern)]
        if matches:
            return matches
        return [self._cli_runtime.Path(pattern)]

    def _flatten_source_to_files(self, path: Path) -> List[Path]:
        """Return a list of valid input files from a file or directory."""
        resolved = path.expanduser()
        try:
            exists = resolved.exists()
        except OSError:
            exists = False

        if not exists:
            print(self.localization.t("file_not_found", path=resolved))
            return []

        if resolved.is_file():
            if resolved.suffix.lower() in self.SUPPORTED_INPUT_SUFFIXES:
                return [resolved]
            print(f"⚠️ Skipping unsupported file: {resolved.name}")
            return []

        if resolved.is_dir():
            files = [
                candidate
                for candidate in sorted(resolved.rglob("*"))
                if candidate.is_file() and candidate.suffix.lower() in self.SUPPORTED_INPUT_SUFFIXES
            ]
            if not files:
                print(f"⚠️ No EPUB/PDF files found in {resolved}")
            return files

        print(f"⚠️ Invalid path: {resolved}")

        return []

    @staticmethod
    def _canonical_path_key(path: Path) -> str:
        try:
            return str(path.resolve())
        except OSError:
            return str(path)

    def _run_batch(
        self,
        args: argparse.Namespace,
        targets: List[Path],
        *,
        hardware_profile=None,
    ) -> int:
        """Execute sequential conversions (or verify/fix) for multiple books."""
        total = len(targets)
        stop_on_error = bool(getattr(args, "batch_stop_on_error", False))
        successes = 0
        exit_code = 0
        failed_books: List[str] = []

        verify_mode = getattr(args, "verify_only", False)
        fix_mode = getattr(args, "fix_mode", False)

        for index, target in enumerate(targets, start=1):
            self._print_batch_header(target, index, total)
            single_args = self._cli_runtime.copy.deepcopy(args)
            single_args.input_file = str(target)
            single_args.extra_inputs = []
            single_args.batch_inputs = []
            single_args.batch_manifest = None
            result = self._run_single_conversion(single_args, hardware_profile=hardware_profile)
            if result == 0:
                successes += 1
            else:
                exit_code = exit_code or result or 1
                failed_books.append(target.name)
                if stop_on_error:
                    print("🛑 Processing interrupted after failure.")
                    break

        if verify_mode:
            label = "verified clean"
        elif fix_mode:
            label = "fixed successfully"
        else:
            label = "succeeded"
        print(f"\n📚 Batch complete: {successes}/{total} book(s) {label}.")
        if failed_books:
            print("   Failed books:")
            for failed in failed_books:
                print(f"   - {failed}")
        return exit_code

    @staticmethod
    def _read_batch_manifest(manifest: Optional[str], *, namespace) -> List[str]:
        if not manifest:
            return []
        manifest_path = namespace.Path(manifest).expanduser()
        if not manifest_path.exists():
            print(f"⚠️ List file not found: {manifest_path}")
            return []
        entries: List[str] = []
        try:
            with manifest_path.open("r", encoding="utf-8") as handle:
                for line in handle:
                    stripped = line.strip()
                    if not stripped or stripped.startswith("#"):
                        continue
                    entries.append(stripped)
        except OSError as exc:
            print(f"⚠️ Failed to read batch list ({manifest_path}): {exc}")
        return entries

    @staticmethod
    def _print_batch_header(target: Path, index: int, total: int) -> None:
        divider = "=" * 60
        print(f"\n{divider}")
        print(f"📘 Book {index}/{total}: {target.name}")
        print(f"{divider}")
