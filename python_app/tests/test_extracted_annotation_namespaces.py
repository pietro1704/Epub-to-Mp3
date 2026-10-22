"""Keep runtime annotation introspection valid at extracted compatibility seams."""

import threading
from typing import Optional, get_type_hints

from src._server_engine_helpers import _auto_tune_engine_pool
from src.converter_text_preparation import ConverterTextPreparation
from src.epub_subchapter_splitting import EpubSubchapterSplitting
from src.hardware_detector import HardwareProfile
from src.text_integrity_validator import TextIntegrityValidator


def test_engine_pool_hardware_annotation_resolves():
    hints = get_type_hints(_auto_tune_engine_pool)
    assert hints["hardware_profile"] is HardwareProfile


def test_text_preparation_validator_annotation_resolves():
    hints = get_type_hints(ConverterTextPreparation._generate_all_text_files)
    assert hints["text_validator"] == Optional[TextIntegrityValidator]


def test_spine_archive_lock_annotation_resolves():
    hints = get_type_hints(EpubSubchapterSplitting._prepare_spine_item)
    assert hints["archive_lock"] is threading.Lock
