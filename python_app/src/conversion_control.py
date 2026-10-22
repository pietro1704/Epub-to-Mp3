# -*- coding: utf-8 -*-
"""Explicit return and loop control between conversion phases."""

from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True, slots=True)
class ConversionControl:
    """Carry an original coordinator return, break or continue across a phase."""

    kind: str
    value: Any = None
