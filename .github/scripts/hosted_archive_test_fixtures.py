"""Shared synthetic archive fixtures; no Apple trust or runtime claim."""

import importlib.util
from pathlib import Path


SOURCE = Path(__file__).with_name("hosted-legacy-ios-archive.py")
SPEC = importlib.util.spec_from_file_location("legacy_archive", SOURCE)
archive = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(archive)

# Exact hosted attach-help receipt from run38906144750/63a3ed6, 03-hdiutil.log.
# Its bracketed autoopen spelling and omitted nobrowse exposed the real gate bug.
REAL_ATTACH_HELP = b"""hdiutil attach: attach disk image
Usage:\thdiutil attach <image>
\tDevice options:
\t    -readonly\t\tforce read-only
\t    -kernel\t\tattempt to attach the image in-kernel

\tMount options:
\t    -mount required|optional|suppressed\t\tmount volumes?
\t    -nomount\t\tsame as -mount suppressed
\t    -mountpoint <path>\tmount at <path> instead of inside /Volumes
\t    -mountroot <path>\tmount volumes on <path>/<volname>
\t    -mountrandom <path>\tmount volumes on <path>/<random>

\tProcessing options (defaults per framework preferences):
\t    -[no]verify\t\t(do not) verify image checksums
\t    -[no]autofsck\t(do not) perform automatic filesystem checks
\t    -[no]autoopen\t(do not) open root of new mounts

\tCommon options:
\t    -encryption <crypto method>
\t    \tAES-128 - 128-bit AES encryption
\t    \tAES-256 - 256-bit AES encryption (recommended)
\t    -stdinpass
\t    -agentpass
\t    -recover <keychain-file>
\t    -imagekey <key>=<value>
\t    -drivekey <key>=<value>
\t    -shadow <shadowfile>
\t    -insecurehttp
\t    -cacert <file | dir>
\t    -plist
\t    -puppetstrings
\t    -verbose
\t    -debug
\t    -quiet
"""


# Entire real pkgutil receipt, run38909806259/66ce7ec, 10-pkgutil.log.
# This fixture validates parsing only, never cryptographic authenticity.
REAL_APPLE_SIGNATURE = """Package "iPhoneSimulatorSDK15_5.pkg":
   Status: signed Apple Software (Development)
   Signed with a trusted timestamp on: 2022-05-26 01:15:02 +0000
   Certificate Chain:
    1. Development Update
       Expires: 2029-04-14 21:28:23 +0000
       SHA256 Fingerprint:
           D8 F1 22 D9 79 88 EB 12 D7 13 7B BD 53 74 E5 5A 9C 4B 38 F5 3D 25
           56 62 27 74 E2 3D DD 55 D3 6A
       ------------------------------------------------------------------------
    2. Apple Software Update Certification Authority
       Expires: 2031-10-15 00:00:00 +0000
       SHA256 Fingerprint:
           12 99 E9 BF E7 76 A2 9F F4 52 F8 C4 F5 E5 5F 3B 4D FD 29 34 34 9D
           D1 85 0B 82 74 F3 5C 71 74 5C
       ------------------------------------------------------------------------
    3. Apple Root CA
       Expires: 2035-02-09 21:40:36 +0000
       SHA256 Fingerprint:
           B0 B1 73 0E CB C7 FF 45 05 14 2C 49 F1 29 5E 6E DA 6B CA ED 7E 2C
           68 C5 BE 91 B5 A1 10 01 F0 24

"""
