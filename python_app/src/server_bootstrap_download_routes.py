# -*- coding: utf-8 -*-
"""Ordered legacy server initialization at the facade seam."""

from __future__ import annotations


def _initialize_server_download_routes(_runtime):
    _runtime.download_output = _runtime.app.api_route("/api/outputs/{job_id}/{filename}", methods=["GET", "HEAD"])(_runtime._bind_server_function(_runtime._server_server_download_routes.download_output, _runtime.sys.modules[_runtime.__name__]))


    _runtime.stream_manifest = _runtime.app.get("/api/streams/{job_id}/chapters/{chapter_index}")(_runtime._bind_server_function(_runtime._server_server_download_routes.stream_manifest, _runtime.sys.modules[_runtime.__name__]))


    _runtime.stream_chunk = _runtime.app.get("/api/streams/{job_id}/chapters/{chapter_index}/chunks/{chunk_id}")(_runtime._bind_server_function(_runtime._server_server_download_routes.stream_chunk, _runtime.sys.modules[_runtime.__name__]))
