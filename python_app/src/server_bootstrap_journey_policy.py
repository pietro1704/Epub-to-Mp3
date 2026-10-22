# -*- coding: utf-8 -*-
"""Ordered legacy server initialization at the facade seam."""

from __future__ import annotations


def _initialize_server_journey_policy(_runtime):
    _runtime._JOURNEY_TRANSITIONS = frozenset(
        {
            "play_requested",
            "audio_queued",
            "audio_audible",
            "seek_requested",
            "seek_target_reached",
            "cancelled",
        }
    )
    _runtime._JOURNEY_OBSERVATION_LIMIT = 200
