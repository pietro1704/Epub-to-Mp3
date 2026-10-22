"""Output integrity/metadata seams keep chapter identity and replaceable probes."""

from types import SimpleNamespace
from unittest.mock import Mock

import pytest
from src._output_file_mixin import _OutputFileMixin
from src.text_integrity_validator import TextIntegrityValidator


class _Host(_OutputFileMixin):
    verbose = False

    def __init__(self):
        self._text_validation_hashes = {}
        self._text_validation_errors = []


def test_text_integrity_keeps_decimal_identity_across_retries(tmp_path):
    host = _Host()
    chapter = SimpleNamespace(text="unique chapter content")
    validator = TextIntegrityValidator(tmp_path)
    arguments = dict(parsed_text=chapter.text, pre_tts_text=chapter.text, validator=validator, strict=False)
    assert host._validate_text_after_save(chapter, "7.1", **arguments)
    assert host._validate_text_after_save(chapter, "7.1", **arguments)
    assert not host._validate_text_after_save(chapter, "7.2", **arguments)
    assert "same as chapter 7.1" in host._text_validation_errors[-1]


def test_text_integrity_strict_failure_and_cancellation_remain_visible(tmp_path, monkeypatch):
    host = _Host()
    chapter = SimpleNamespace(text="expected content")
    validator = TextIntegrityValidator(tmp_path)
    with pytest.raises(RuntimeError, match="Post-parsing validation failed"):
        host._validate_text_after_save(chapter, "1", "", "", validator=validator, strict=True)
    monkeypatch.setattr(validator, "normalize_text", Mock(side_effect=KeyboardInterrupt))
    with pytest.raises(KeyboardInterrupt):
        host._validate_text_after_save(chapter, "1", "text", "text", validator=validator, strict=False)


@pytest.mark.parametrize("generated, expected", [(96, True), (50, False)])
def test_audio_segment_integrity_retains_literal_ratio_policy(generated, expected, monkeypatch):
    monkeypatch.setenv("EDGE_SEGMENT_OK_RATIO", "0.95")
    engine = SimpleNamespace(last_segment_report={"expected": 100, "generated": generated, "failed": 100 - generated})
    assert _Host()._edge_segment_integrity_ok(engine)[0] is expected


def test_audio_validation_keeps_corruption_failure_and_best_effort_probe_error(tmp_path, monkeypatch):
    validator = Mock()
    monkeypatch.setattr("src.audio_validator.AudioValidator", Mock(return_value=validator))
    validator.validate_audio_file.return_value = False
    host = _Host()
    assert host._validate_audio_after_write("text", tmp_path / "chapter.mp3", config=SimpleNamespace()) == (
        False, "Invalid or corrupted audio"
    )
    validator.validate_audio_file.side_effect = OSError("probe failed")
    assert host._validate_audio_after_write("text", tmp_path / "chapter.mp3", config=SimpleNamespace()) == (True, None)
    validator.validate_audio_file.side_effect = KeyboardInterrupt
    with pytest.raises(KeyboardInterrupt):
        host._validate_audio_after_write("text", tmp_path / "chapter.mp3", config=SimpleNamespace())


def test_final_metadata_preserves_file_and_cover_identity_and_skips_missing_outputs(tmp_path):
    host = _Host()
    output = tmp_path / "1 - Chapter.mp3"
    output.write_bytes(b"audio")
    ignored = tmp_path / "notes.txt"
    ignored.write_text("text")
    cover = {"data": b"image", "mime": "image/png"}
    host._embed_id3_metadata = Mock()
    host._apply_final_id3_tags([output, ignored, tmp_path / "missing.mp3"], default_album=None, artist="Fixture", cover_art=cover)
    host._embed_id3_metadata.assert_called_once_with(
        output, title="Chapter", album=tmp_path.name, artist="Fixture", cover_art=cover
    )
