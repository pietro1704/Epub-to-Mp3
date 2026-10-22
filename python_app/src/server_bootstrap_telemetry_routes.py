# -*- coding: utf-8 -*-
"""Ordered legacy server initialization at the facade seam."""

from __future__ import annotations


def _initialize_server_telemetry_routes(_runtime):
    _runtime.estimate_conversion = _runtime.app.get("/api/estimate")(_runtime._bind_server_function(_runtime._server_server_telemetry_routes.estimate_conversion, _runtime.sys.modules[_runtime.__name__]))


    _runtime.get_engine_telemetry = _runtime.app.get("/api/telemetry")(_runtime._bind_server_function(_runtime._server_server_telemetry_routes.get_engine_telemetry, _runtime.sys.modules[_runtime.__name__]))


    _runtime.get_segment_telemetry = _runtime.app.get("/api/telemetry/segments")(_runtime._bind_server_function(_runtime._server_server_telemetry_routes.get_segment_telemetry, _runtime.sys.modules[_runtime.__name__]))


    _runtime.get_feature_ab_history = _runtime.app.get("/api/telemetry/feature-history")(_runtime._bind_server_function(_runtime._server_server_telemetry_routes.get_feature_ab_history, _runtime.sys.modules[_runtime.__name__]))
