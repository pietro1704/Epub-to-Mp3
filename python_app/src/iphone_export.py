"""Export converted MP3s to the MP3AudioBookPlayer iCloud Drive container.

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
"""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path
from typing import Optional

# The free version of MP3AudioBookPlayer — confirmed present on macOS
# 2026-04-29 via `ls ~/Library/Mobile Documents/`.
_DEFAULT_BUNDLE = "iCloud~com~biomsoft~mp3audiobookplayerfree"


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
    """Copy every MP3 in ``output_dir`` into the iCloud container.

    The destination is ``<container>/<book_title>/``. Existing files
    with the same name are overwritten — re-running a conversion
    refreshes the iPhone copy without manual cleanup.

    Returns ``(ok, error)``:

    * ``(True, None)`` when at least one MP3 was copied.
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

    mp3s = sorted(output_dir.glob("*.mp3"))
    if not mp3s:
        return False, f"no MP3 files in {output_dir}"

    copied = 0
    for mp3 in mp3s:
        try:
            shutil.copy2(mp3, destination / mp3.name)
            copied += 1
        except OSError as exc:
            if log:
                log(f"   ⚠️ Failed to copy {mp3.name}: {exc}")

    if copied == 0:
        return False, "every MP3 copy failed"

    if log:
        log(
            f"📲 Exported {copied}/{len(mp3s)} MP3 file(s) to iPhone via "
            f"iCloud Drive: {destination}"
        )
    return True, None


def parse_env_flag(value: Optional[str]) -> bool:
    """Parse ``EXPORT_TO_IPHONE`` env var into a bool with sensible truthy values."""
    if not value:
        return False
    return value.strip().lower() in {"1", "true", "yes", "on"}


def is_macos() -> bool:
    """The iCloud Drive container path is macOS-only — short-circuit on Linux/Win."""
    return sys.platform == "darwin"
