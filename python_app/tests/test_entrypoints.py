from __future__ import annotations

from importlib import reload


def test_cli_and_server_share_same_fastapi_app():
    """Ensure the Hugging Face entrypoint exposes the same FastAPI app object used locally."""
    import hf_app
    import python_app.server as server

    # Reload to ensure the import path executed with any recent changes.
    reload(hf_app)
    assert hf_app.app is server.app
