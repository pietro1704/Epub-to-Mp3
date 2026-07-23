from __future__ import annotations


def test_cli_and_server_share_same_fastapi_app():
    """Ensure the Hugging Face entrypoint exposes the same FastAPI app object used locally."""
    import hf_app
    import python_app.server as server

    assert hf_app.app is server.app
