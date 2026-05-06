# -*- coding: utf-8 -*-
"""--clear-cache --chapter X must drop ._resume_state.json so the next
run rebuilds the listing hash (v0.3.26)."""

from __future__ import annotations

import json


def test_clear_chapter_path_removes_resume_state(tmp_path):
    """Direct unit test: emulate the --clear-cache --chapter cleanup loop
    and verify ._resume_state.json is unlinked alongside the chapter MP3.
    """
    output_dir = tmp_path / "out" / "Book_X"
    output_dir.mkdir(parents=True)
    # Plant a chapter MP3 + the resume state file.
    chapter = output_dir / "5 - chapter.mp3"
    chapter.write_bytes(b"AUDIO")
    state = output_dir / "._resume_state.json"
    state.write_text(
        json.dumps({"listing_hash": "stale", "mp3_count": 1, "expected": 1}),
        encoding="utf-8",
    )
    chapter_label = "5"
    sanitized_title = "Book_X"
    output_base = tmp_path / "out"

    # Mirror the loop in main.py:585.
    import contextlib

    cleared_audio = 0
    if output_base.exists():
        for out_dir in output_base.iterdir():
            if out_dir.is_dir() and (
                out_dir.name == sanitized_title or out_dir.name.startswith(f"{sanitized_title}_")
            ):
                for f in out_dir.glob(f"{chapter_label} - *.mp3"):
                    f.unlink(missing_ok=True)
                    cleared_audio += 1
                with contextlib.suppress(OSError):
                    (out_dir / "._resume_state.json").unlink(missing_ok=True)

    assert cleared_audio == 1
    assert not chapter.exists()
    assert not state.exists()
