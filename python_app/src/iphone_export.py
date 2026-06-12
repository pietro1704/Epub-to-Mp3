"""Export converted audiobooks to the MP3AudioBookPlayer iCloud Drive container.

Mechanism: macOS-only feature that copies the finished audiobook into
``~/Library/Mobile Documents/iCloud~com~biomsoft~mp3audiobookplayerfree/Documents/<book>/``.
iCloud Drive then syncs the folder to the iPhone, where the
MP3AudioBookPlayer app picks it up automatically (the bundle ID
``com.biomsoft.mp3audiobookplayerfree`` exposes its `Documents` folder
through iCloud + the iOS Files app under the path
``Arquivos > MP3AudioBookPlayer``).

Why iCloud Drive and not USB / AirDrop / libimobiledevice:

* USB sync requires `libimobiledevice` + `ifuse` (brew dependency, fuse
  kext on Apple Silicon, manual "trust this computer" prompt) and only
  works while the cable is connected.
* AirDrop requires manual confirmation on every transfer.
* iCloud Drive is the only path that's fully unattended once the user
  is signed into their iCloud account, works over WiFi or cellular, and
  doesn't need a separate dependency on the Mac side.

The export is **opt-in** — disabled by default, enabled via
``--export-to-iphone`` on the CLI or ``EXPORT_TO_IPHONE=1`` in the env.
The container path is overridable via ``IPHONE_EXPORT_DIR`` so users
with a different audiobook player (e.g. the paid-tier
``com.biomsoft.MP3AudiobookPlayer``) can point at their bundle.

The queue prefers AAC-in-M4A when possible because iOS handles it more
natively and it is smaller than MP3 at audiobook bitrates. Set
``IPHONE_EXPORT_FORMAT=mp3`` to force legacy MP3 copies. If M4A
transcoding fails, export falls back to MP3 rather than dropping the
book from the queue.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Optional

# The free version of MP3AudioBookPlayer — confirmed present on macOS
# 2026-04-29 via `ls ~/Library/Mobile Documents/`.
_DEFAULT_BUNDLE = "iCloud~com~biomsoft~mp3audiobookplayerfree"
_AUDIO_EXTENSIONS = (".m4a", ".mp3")


def default_export_root() -> Path:
    """Return the default iCloud Drive container path on this Mac."""
    override = os.environ.get("IPHONE_EXPORT_DIR", "").strip()
    if override:
        return Path(override).expanduser()
    return Path.home() / "Library" / "Mobile Documents" / _DEFAULT_BUNDLE / "Documents"


def is_export_target_available(target: Optional[Path] = None) -> bool:
    """True when the iCloud container exists, signed in, and writable.

    Splits the check into separate concerns so the failure message can
    be specific:

    * container missing → app likely not installed on a paired device.
    * container exists but write fails → iCloud signed out, quota
      exhausted, or the user blocked the Mac from syncing.
    """
    target = target or default_export_root()
    parent = target.parent
    return parent.exists() and os.access(parent, os.W_OK)


def export_book_to_iphone(
    output_dir: Path,
    book_title: str,
    *,
    target_root: Optional[Path] = None,
    log: Optional[callable] = None,
) -> tuple[bool, Optional[str]]:
    """Copy every audio file in ``output_dir`` into the iCloud container.

    The destination is ``<container>/<book_title>/``. Existing files
    with the same name are overwritten — re-running a conversion
    refreshes the iPhone copy without manual cleanup.

    Returns ``(ok, error)``:

    * ``(True, None)`` when at least one audio file was queued.
    * ``(False, "<reason>")`` when the container isn't reachable, the
      output directory is empty, or copy raised. Errors are surfaced
      via the return value rather than raised so the conversion
      pipeline never fails just because the export step did — the
      synthesised audio is still on disk regardless.
    """
    output_dir = Path(output_dir)
    if not output_dir.exists() or not output_dir.is_dir():
        return False, f"output directory not found: {output_dir}"

    target_root = (target_root or default_export_root()).expanduser()
    if not target_root.parent.exists():
        return False, (
            f"iCloud container not found: {target_root.parent}. "
            "Install MP3AudioBookPlayer on a paired iPhone (or set "
            "IPHONE_EXPORT_DIR to point at another container)."
        )

    safe_book_title = (book_title or output_dir.name).strip() or "Audiobook"
    # iCloud Drive accepts the same charset as macOS HFS+ — the strings
    # we already let into output filenames are fine here. We only strip
    # leading/trailing slashes to avoid escaping the container.
    safe_book_title = safe_book_title.replace("/", "_").replace("\\", "_")

    destination = target_root / safe_book_title
    try:
        destination.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        return False, f"could not create destination {destination}: {exc}"

    audio_files = sorted(
        path
        for path in output_dir.iterdir()
        if path.is_file() and path.suffix.lower() in _AUDIO_EXTENSIONS
    )
    if not audio_files:
        return False, f"no audio files in {output_dir}"

    preferred_format = os.environ.get("IPHONE_EXPORT_FORMAT", "m4a").strip().lower()
    prefer_m4a = preferred_format not in {"mp3", ".mp3"}

    copied = 0
    for audio in audio_files:
        try:
            exported = _copy_for_iphone_queue(audio, destination, prefer_m4a=prefer_m4a)
            if exported is None:
                if log:
                    log(f"   ⚠️ Failed to export {audio.name}")
                continue
            copied += 1
        except OSError as exc:
            if log:
                log(f"   ⚠️ Failed to copy {audio.name}: {exc}")

    if copied == 0:
        return False, "every audio copy failed"

    if log:
        log(
            f"📲 Exported {copied}/{len(audio_files)} audio file(s) to iPhone via "
            f"iCloud Drive: {destination}"
        )
    return True, None


def _copy_for_iphone_queue(source: Path, destination: Path, *, prefer_m4a: bool) -> Optional[Path]:
    """Queue one file, preferring M4A and falling back to MP3 when needed."""
    source = Path(source)
    destination.mkdir(parents=True, exist_ok=True)

    if prefer_m4a:
        if source.suffix.lower() == ".m4a":
            target = destination / source.name
            shutil.copy2(source, target)
            _remove_alternate_format(destination, target)
            return target

        m4a_target = destination / f"{source.stem}.m4a"
        if _transcode_to_m4a(source, m4a_target):
            _remove_alternate_format(destination, m4a_target)
            return m4a_target

    target = destination / source.name
    shutil.copy2(source, target)
    _remove_alternate_format(destination, target)
    return target


def _remove_alternate_format(destination: Path, kept: Path) -> None:
    """Remove stale same-stem MP3/M4A duplicates after queueing the preferred format."""
    for suffix in _AUDIO_EXTENSIONS:
        candidate = Path(destination) / f"{kept.stem}{suffix}"
        if candidate != kept:
            candidate.unlink(missing_ok=True)


def _transcode_to_m4a(source: Path, target: Path) -> bool:
    """Transcode ``source`` to AAC-in-M4A, returning False on any ffmpeg failure."""
    if not shutil.which("ffmpeg"):
        return False

    tmp_target = target.with_suffix(f"{target.suffix}.tmp")
    tmp_target.unlink(missing_ok=True)
    try:
        result = subprocess.run(
            (
                "ffmpeg",
                "-y",
                "-i",
                str(source),
                "-vn",
                "-c:a",
                "aac",
                "-b:a",
                "64k",
                "-ar",
                "22050",
                "-ac",
                "1",
                "-movflags",
                "+faststart",
                str(tmp_target),
            ),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if result.returncode != 0 or not tmp_target.exists() or tmp_target.stat().st_size < 1024:
            tmp_target.unlink(missing_ok=True)
            return False
        if target.exists():
            target.unlink()
        tmp_target.replace(target)
        return True
    except OSError:
        tmp_target.unlink(missing_ok=True)
        return False


def parse_env_flag(value: Optional[str]) -> bool:
    """Parse ``EXPORT_TO_IPHONE`` env var into a bool with sensible truthy values."""
    if not value:
        return False
    return value.strip().lower() in {"1", "true", "yes", "on"}


def is_macos() -> bool:
    """The iCloud Drive container path is macOS-only — short-circuit on Linux/Win."""
    return sys.platform == "darwin"
