"""Named engine scenarios and result values for single-chapter benchmarks."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List

@dataclass(frozen=True)
class Scenario:
    key: str
    label: str
    engine: str
    mode: str
    description: str


SCENARIOS: Dict[str, Scenario] = {
    "edge_multi": Scenario(
        key="edge_multi",
        label="Edge multilingual",
        engine="edge",
        mode="edge-multilingual",
        description="Default multilingual voice with automatic language detection [[lang:xx]].",
    ),
    "edge_pt": Scenario(
        key="edge_pt",
        label="Edge pt-BR monolingual",
        engine="edge",
        mode="edge-monolingual",
        description="Forces pt-BR monolingual voice to avoid multilingual rate limiting.",
    ),
    "piper": Scenario(
        key="piper",
        label="Piper local pt-BR",
        engine="piper",
        mode="piper",
        description="Offline synthesis using the recommended Piper pt-BR model.",
    ),
}

# Publicly known community values for Edge TTS rate limits.
EDGE_RATE_LIMIT_HINTS = {
    "edge-multilingual": 10,  # ~10 req/s for MultilingualNeural voices
    "edge-monolingual": 16,  # ~16 req/s for traditional pt-BR Neural voices
}


@dataclass
class ScenarioResult:
    scenario: Scenario
    elapsed: float
    chars_per_sec: float
    chapter_chars: int
    success: bool
    output_files: List[Path]
    errors: List[str]
