from __future__ import annotations

import plistlib
import xml.etree.ElementTree as ET
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
ANDROID_NS = "{http://schemas.android.com/apk/res/android}"


def _android_activity_filters() -> list[ET.Element]:
    manifest = PROJECT_ROOT / "flutter_app/android/app/src/main/AndroidManifest.xml"
    root = ET.parse(manifest).getroot()
    activity = root.find("./application/activity")
    assert activity is not None, "MainActivity declaration is missing"
    return list(activity.findall("intent-filter"))


def _filter_actions(intent_filter: ET.Element) -> set[str]:
    return {
        node.attrib[f"{ANDROID_NS}name"]
        for node in intent_filter.findall("action")
        if f"{ANDROID_NS}name" in node.attrib
    }


def _filter_mime_types(intent_filter: ET.Element) -> set[str]:
    return {
        node.attrib[f"{ANDROID_NS}mimeType"]
        for node in intent_filter.findall("data")
        if f"{ANDROID_NS}mimeType" in node.attrib
    }


def test_android_app_is_associated_with_supported_book_documents() -> None:
    filters = _android_activity_filters()

    view_mimes: set[str] = set()
    send_mimes: set[str] = set()
    for intent_filter in filters:
        actions = _filter_actions(intent_filter)
        mimes = _filter_mime_types(intent_filter)
        if "android.intent.action.VIEW" in actions:
            view_mimes.update(mimes)
        if "android.intent.action.SEND" in actions:
            send_mimes.update(mimes)

    assert {"application/epub+zip", "application/pdf"}.issubset(view_mimes)
    assert {"application/epub+zip", "application/pdf"}.issubset(send_mimes)


def test_ios_app_declares_document_types_for_supported_book_documents() -> None:
    info_plist = PROJECT_ROOT / "ios/EpubToMp3/EpubToMp3/Resources/Info.plist"
    with info_plist.open("rb") as fh:
        plist = plistlib.load(fh)

    declared_types: set[str] = set()
    for doc_type in plist.get("CFBundleDocumentTypes", []):
        declared_types.update(doc_type.get("LSItemContentTypes", []))

    assert "org.idpf.epub-container" in declared_types
    assert "com.apple.ibooks.epub" in declared_types
    assert "public.epub" in declared_types
    assert "com.adobe.pdf" in declared_types
    assert "public.pdf" in declared_types


def test_android_shortcut_labels_use_string_resources() -> None:
    shortcuts = PROJECT_ROOT / "flutter_app/android/app/src/main/res/xml/shortcuts.xml"
    root = ET.parse(shortcuts).getroot()
    shortcut = root.find("shortcut")
    assert shortcut is not None

    for attribute in ("shortcutShortLabel", "shortcutLongLabel"):
        value = shortcut.attrib[f"{ANDROID_NS}{attribute}"]
        assert value.startswith(
            "@string/"
        ), f"Android {attribute} must reference a string resource, not a literal"
