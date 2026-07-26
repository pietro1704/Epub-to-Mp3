"""Tests for MOBI/AZW DRM detection via the raw PalmDOC/MOBI header."""

import struct
from pathlib import Path

import pytest
from src.mobi_drm import MobiDrmProtectedError, detect_mobi_drm, raise_if_drm_protected


def _make_mobi_bytes(encryption_type: int, *, valid_type_creator: bool = True) -> bytes:
    pdb_header = bytearray(78)
    if valid_type_creator:
        pdb_header[60:68] = b"BOOKMOBI"
    struct.pack_into(">H", pdb_header, 76, 1)  # numberOfRecords = 1

    record0_offset = 78 + 8
    record_info = struct.pack(">I", record0_offset) + b"\x00\x00\x00\x00"

    record0 = bytearray(20)
    struct.pack_into(">H", record0, 12, encryption_type)

    return bytes(pdb_header) + record_info + bytes(record0)


def _write(tmp_path: Path, name: str, data: bytes) -> Path:
    path = tmp_path / name
    path.write_bytes(data)
    return path


def test_encryption_type_zero_is_not_drm(tmp_path):
    path = _write(tmp_path, "clean.mobi", _make_mobi_bytes(0))
    assert detect_mobi_drm(path) is False


def test_encryption_type_two_is_amazon_drm(tmp_path):
    path = _write(tmp_path, "protected.azw3", _make_mobi_bytes(2))
    assert detect_mobi_drm(path) is True


def test_encryption_type_one_is_also_drm(tmp_path):
    # Old Mobipocket encryption — still not something this app can open.
    path = _write(tmp_path, "old-encryption.mobi", _make_mobi_bytes(1))
    assert detect_mobi_drm(path) is True


def test_raise_if_drm_protected_raises_for_protected_file(tmp_path):
    path = _write(tmp_path, "protected.mobi", _make_mobi_bytes(2))
    with pytest.raises(MobiDrmProtectedError):
        raise_if_drm_protected(path)


def test_raise_if_drm_protected_is_silent_for_clean_file(tmp_path):
    path = _write(tmp_path, "clean.mobi", _make_mobi_bytes(0))
    raise_if_drm_protected(path)  # must not raise


def test_non_mobi_type_creator_returns_false_not_crash(tmp_path):
    path = _write(tmp_path, "notmobi.mobi", _make_mobi_bytes(2, valid_type_creator=False))
    assert detect_mobi_drm(path) is False


def test_truncated_file_returns_false_not_crash(tmp_path):
    path = _write(tmp_path, "truncated.mobi", b"too short")
    assert detect_mobi_drm(path) is False


def test_missing_file_returns_false_not_crash(tmp_path):
    assert detect_mobi_drm(tmp_path / "does-not-exist.mobi") is False
