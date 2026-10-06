"""DRM detection for MOBI/AZW/AZW3 files, by reading the raw PalmDOC/MOBI
header — no dependency on the `mobi` unpacking library, which doesn't
expose this check and shouldn't be given a chance to choke on a protected
file in the first place.

Layout (big-endian, all documented in the public MOBI/PDB format spec used
by Calibre, KindleUnpack, etc.):

- PDB header: 78 bytes. `numberOfRecords` is a 2-byte field at offset 76.
  `type`/`creator` (4 ASCII bytes each) at offsets 60/64 identify a real
  MOBI container ("BOOKMOBI").
- Record info list starts right after the PDB header (offset 78); each
  entry is 8 bytes, the first 4 being record 0's file offset.
- Record 0 holds the PalmDOC header. Its `Encryption Type` field is a
  2-byte value at offset +12: 0 = none, 1 = old Mobipocket encryption,
  2 = Mobipocket/Amazon DRM. Both non-zero values are real DRM and must be
  rejected — "old" encryption is still not something this app can open.

This is a best-effort structural check, not a cryptographic one — like the
existing PDF `document.isEncrypted` check, it can't catch a hypothetical
future protection scheme it doesn't know about.
"""

from __future__ import annotations

import struct
from pathlib import Path

_PDB_HEADER_SIZE = 78
_TYPE_CREATOR_OFFSET = 60
_RECORD_INFO_SIZE = 8
_ENCRYPTION_TYPE_OFFSET = 12


class MobiDrmProtectedError(Exception):
    """Raised when a MOBI/AZW/AZW3 file is protected by DRM."""


def detect_mobi_drm(path: str | Path) -> bool:
    """Return True if the file's PalmDOC header reports non-zero Encryption
    Type. Returns False (not our call to make) for anything that doesn't
    look like a recognizable MOBI/PDB container — a genuinely corrupt file
    will fail later in the real parser with a clearer error."""
    try:
        with open(path, "rb") as f:
            header = f.read(_PDB_HEADER_SIZE)
            if len(header) < _PDB_HEADER_SIZE:
                return False
            type_creator = header[_TYPE_CREATOR_OFFSET : _TYPE_CREATOR_OFFSET + 8]
            if type_creator != b"BOOKMOBI":
                return False
            (num_records,) = struct.unpack(">H", header[76:78])
            if num_records < 1:
                return False

            record_info = f.read(_RECORD_INFO_SIZE)
            if len(record_info) < _RECORD_INFO_SIZE:
                return False
            (record0_offset,) = struct.unpack(">I", record_info[0:4])

            f.seek(record0_offset + _ENCRYPTION_TYPE_OFFSET)
            enc_bytes = f.read(2)
            if len(enc_bytes) < 2:
                return False
            (encryption_type,) = struct.unpack(">H", enc_bytes)
            return encryption_type != 0
    except OSError:
        return False


def raise_if_drm_protected(path: str | Path) -> None:
    if detect_mobi_drm(path):
        raise MobiDrmProtectedError(
            "This MOBI/AZW file is protected by Amazon DRM and can't be "
            "converted. Remove the protection with an authorized Amazon "
            "tool before importing."
        )


__all__ = ["detect_mobi_drm", "raise_if_drm_protected", "MobiDrmProtectedError"]
