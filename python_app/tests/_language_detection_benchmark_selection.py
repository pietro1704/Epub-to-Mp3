"""Language detection and engine-selection policy for the manual benchmark."""

from python_app.tests._language_detection_benchmark_support import (
    ENGINE_LANGUAGE_SUPPORT as ENGINE_LANGUAGE_SUPPORT,
)
from python_app.tests._language_detection_benchmark_support import (
    LANGUAGE_VOICES as LANGUAGE_VOICES,
)
from python_app.tests._language_detection_benchmark_support import (
    LangDetectException as LangDetectException,
)
from python_app.tests._language_detection_benchmark_support import List as List
from python_app.tests._language_detection_benchmark_support import Tuple as Tuple
from python_app.tests._language_detection_benchmark_support import detect as detect


def detect_language(text: str) -> str:
    """Detect language of text using langdetect."""
    try:
        detected = detect(text)
        # Map some variants
        lang_map = {"pt": "pt", "en": "en", "es": "es", "ja": "ja", "zh-cn": "zh", "zh-tw": "zh"}
        return lang_map.get(detected, detected)
    except LangDetectException:
        return "en"  # Default fallback


def select_best_engine_for_language(lang: str, available_engines: List[str]) -> Tuple[str, str]:
    """
    Select the best engine for a specific language.
    Returns (engine_name, voice).

    Priority: Fast local engines > Slow local > Cloud
    """
    # Priority order for language-specific routing
    priority_order = ["kokoro", "piper", "edge"]

    for engine in priority_order:
        if engine not in available_engines:
            continue
        if lang in ENGINE_LANGUAGE_SUPPORT.get(engine, set()):
            voice = LANGUAGE_VOICES.get(engine, {}).get(lang, "")
            return engine, voice

    # Fallback to Edge (multilingual)
    return "edge", LANGUAGE_VOICES.get("edge", {}).get(lang, "pt-BR-ThalitaMultilingualNeural")
