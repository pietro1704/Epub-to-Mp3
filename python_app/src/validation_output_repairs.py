"""Classify validation findings and repair only the corresponding output artifacts."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Set


def dedup_chapter_outputs(output_dir: Path, *, verbose) -> int:
    """Collapse duplicate MP3s for the same chapter label.

    Two situations produce duplicates we want to clean up
    automatically:

    1. Re-runs with slightly different filename truncations leave
       one short and one long version (the v0.3.16 stable hash
       addresses this for new conversions but doesn't retroactively
       fix older artefacts already on disk).
    2. A reconversion of a single chapter writes a new file while
       the legacy one persists.

    Strategy: group MP3s by their leading ``<label> - `` prefix.
    Keep the file with the longest *audio duration* — the longer
    track is almost always the more complete output. Drop the rest.

    Returns the number of files removed.
    """
    import re as _re
    import subprocess as _subprocess
    from collections import defaultdict as _defaultdict

    if not output_dir or not output_dir.exists():
        return 0

    label_re = _re.compile(r"^([\d.]+)\s+-\s+")
    groups: dict[str, list[Path]] = _defaultdict(list)
    for mp3 in output_dir.glob("*.mp3"):
        match = label_re.match(mp3.name)
        if not match:
            continue
        groups[match.group(1)].append(mp3)

    ffprobe_failures = 0

    def _duration(path: Path) -> float:
        nonlocal ffprobe_failures
        try:
            out = _subprocess.run(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-show_entries",
                    "format=duration",
                    "-of",
                    "default=noprint_wrappers=1:nokey=1",
                    str(path),
                ],
                capture_output=True,
                text=True,
                timeout=15,
            )
            return float(out.stdout.strip() or 0.0)
        except Exception:
            # ffprobe missing or refused the file — note it so the
            # caller knows the dedup downgraded to file-size only,
            # then return 0.0 so the size tie-break below still
            # produces a deterministic winner.
            ffprobe_failures += 1
            return 0.0

    removed = 0
    for label, files in groups.items():
        if len(files) <= 1:
            continue
        # When ffprobe reports duration, longer audio wins (more of
        # the chapter actually got synthesised). When it doesn't, the
        # tuple falls back to file size — still deterministic, and
        # bigger MP3 is almost always the more complete track.
        scored = [(_duration(f), f.stat().st_size, f) for f in files]
        scored.sort(key=lambda t: (t[0], t[1]), reverse=True)
        for _dur, _size, loser in scored[1:]:
            try:
                loser.unlink()
                removed += 1
            except OSError:
                pass
    if ffprobe_failures and verbose():
        print(
            f"   ⚠️ Auto-dedup: ffprobe failed on {ffprobe_failures} file(s); "
            "ranking by file size only."
        )
    return removed


def categorize_problems(issues: list, problem_chapters: list) -> tuple[list, list]:
    """
    Categorize problems to decide reconversion strategy.

    Returns:
        Tuple of (missing_mp3_only, duration_only) chapter lists
    """
    missing_mp3_only = []
    duration_only = []

    for chapter_num in problem_chapters:
        chapter_issues = [issue for issue in issues if f"Chapter {chapter_num}" in issue]
        if not chapter_issues:
            continue

        tags: Set[str] = set()
        for issue in chapter_issues:
            issue_l = issue.lower()
            if "missing mp3" in issue_l:
                tags.add("missing_mp3")
            elif "duration mismatch" in issue_l:
                tags.add("duration")
            else:
                # Any other validation issue (missing cache, text mismatch, HTML, duplicates, etc.)
                # must trigger full chapter reconversion.
                tags.add("other")

        if tags == {"missing_mp3"}:
            missing_mp3_only.append(chapter_num)
        elif tags == {"duration"}:
            # Duration-only issue (text and MP3 exist but duration off)
            duration_only.append(chapter_num)

    return missing_mp3_only, duration_only


def remove_bad_mp3s(output_dir: Path, issues: list, problem_chapters: list) -> list[str]:
    """
    Remove bad MP3s before reconverting to avoid conflicts.

    Extracts MP3 names from validation issues (incorrect name, duplicate,
    wrong duration) and removes them from the output directory.

    Returns:
        List of removed file names.
    """
    removed = []
    mp3_filenames_to_remove: set[str] = set()

    for issue in issues:
        # "MP3 filename 'xxx.mp3' does not match EPUB heading"
        match = re.search(r"MP3 filename '([^']+\.mp3)'", issue)
        if match:
            mp3_filenames_to_remove.add(match.group(1))

        # "MP3 filename contains HTML/markup: xxx.mp3"
        match = re.search(r"HTML/markup:\s*(.+\.mp3)", issue)
        if match:
            mp3_filenames_to_remove.add(match.group(1).strip())

    # Also remove MP3s for chapters with duration mismatch or duplicates
    # by matching chapter number patterns in existing MP3 filenames
    problem_set = set(str(ch) for ch in problem_chapters)
    if output_dir.exists():
        for mp3_file in output_dir.glob("*.mp3"):
            # Extract chapter number from filename (e.g. "4.1 - ..." or "004 - ...")
            stem = mp3_file.name
            # Match decimal index: "4.1 - ...", "10.5 - ..."
            ch_match = re.match(r"^(\d+\.\d+)\s*-\s*", stem)
            if not ch_match:
                # Match zero-padded: "004 - ..."
                ch_match = re.match(r"^0*(\d+)\s*-\s*", stem)
            if ch_match:
                ch_num = ch_match.group(1)
                if ch_num in problem_set:
                    mp3_filenames_to_remove.add(mp3_file.name)

    # Remove the files
    for fname in mp3_filenames_to_remove:
        mp3_path = output_dir / fname
        if mp3_path.exists():
            mp3_path.unlink()
            removed.append(fname)

    return removed
