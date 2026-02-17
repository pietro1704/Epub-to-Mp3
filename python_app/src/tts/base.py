# -*- coding: utf-8 -*-
"""Ultra-simplified TTS Base - Just protocol definition"""

from pathlib import Path
from typing import Any, Dict, List, Optional, Protocol


class TTSEngine(Protocol):
    """TTS Engine interface"""

    def supports_multilingual(self) -> bool:
        """Return True if engine can handle [[lang:xx]] tags for language switching"""
        ...

    def supports_emphasis(self) -> bool:
        """Return True if engine can handle formatting/emphasis markers"""
        ...

    async def synthesize_async(
        self,
        text: str,
        output_path: Path,
        formatting_segments=None,
        progress_callback=None,
        chunk_callback=None,
        pre_segment_callback=None,
    ) -> Path:
        """Synthesize text to audio file"""
        ...

    def get_synthesis_log(self) -> List[Dict[str, Any]]:
        """
        Return log of all segments processed during last synthesis.

        Returns:
            List of dictionaries with segment information (index, text, status, etc.)
        """
        ...

    def get_synthesis_tracker(self) -> Optional[Any]:
        """
        Return the SynthesisTracker instance used for last synthesis.

        Returns:
            SynthesisTracker instance, or None if not available
        """
        ...
