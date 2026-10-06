"""Regression: iOS bootstrap script must embed `python_app/version.py`.

`python_app/__init__.py` runs `from python_app.version import __version__`
at import time. The iOS app bundles a slim site-packages tree built by
`ios/EpubToMp3/scripts/bootstrap-ios-python.sh`. An earlier revision of
that script copied `__init__.py` and `src/` but forgot `version.py`,
which caused every chapter synthesis to crash with:

    No module named 'python_app.version'

…spamming the main actor with hundreds of identical error records and
freezing the reader. This test pins the script behaviour so the file is
always copied alongside `__init__.py`.
"""

from __future__ import annotations

from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "ios" / "EpubToMp3" / "scripts" / "bootstrap-ios-python.sh"


def test_bootstrap_script_copies_version_py() -> None:
    """The script must copy `version.py` into the embedded python_app."""
    assert SCRIPT.is_file(), f"Bootstrap script missing at {SCRIPT}"
    body = SCRIPT.read_text(encoding="utf-8")
    assert 'cp "${PYAPP_SRC}/version.py"' in body, (
        "bootstrap-ios-python.sh must copy python_app/version.py — "
        "without it the embedded interpreter raises "
        "`No module named 'python_app.version'` on first import."
    )


def test_python_app_init_still_imports_version() -> None:
    """If __init__ no longer imports `version`, relax the script test."""
    init_body = (REPO_ROOT / "python_app" / "__init__.py").read_text(encoding="utf-8")
    assert "from python_app.version import" in init_body, (
        "If you removed `from python_app.version import __version__` "
        "from python_app/__init__.py, the bootstrap-script copy step "
        "may also be droppable — re-evaluate the iOS embed list."
    )


def test_runtime_sync_signs_ios_extension_modules() -> None:
    """iPhone builds must sign copied CPython ``.so`` modules before packaging.

    iOS refuses to dlopen an unsigned extension module from the app bundle.
    The ``_struct`` failure would otherwise make the canonical EPUB parser
    unavailable at runtime even though the framework itself was embedded.
    """
    script = REPO_ROOT / "ios" / "EpubToMp3" / "scripts" / "sync-embedded-python-runtime.sh"
    body = script.read_text(encoding="utf-8")
    assert '[[ "${PLATFORM}" == "iphoneos" ]]' in body
    assert '"${EXPANDED_CODE_SIGN_IDENTITY}"' in body
    assert 'find "${DESTINATION}" -type f -name "*.so" -print0' in body
    assert "/usr/bin/codesign --force --sign" in body
