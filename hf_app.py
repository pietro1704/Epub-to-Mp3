#!/usr/bin/env python3
"""
Hugging Face Space: EPUB to MP3 Converter
Serves React frontend + FastAPI backend in one app
"""

import logging
import sys
from contextlib import asynccontextmanager
from pathlib import Path

# Configure logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

# Add python_app to path
sys.path.insert(0, str(Path(__file__).parent / "python_app"))

logger.info("Starting HF app initialization...")

try:
    from fastapi.responses import FileResponse
    from fastapi.staticfiles import StaticFiles

    from python_app.server import app as api_app

    logger.info("Successfully imported server modules")
except Exception as e:
    logger.error(f"Failed to import modules: {e}", exc_info=True)
    raise

# Reuse the same FastAPI instance defined in python_app.server
app = api_app
logger.info("FastAPI app initialized")

# Serve static files from web/dist
web_dist = Path(__file__).parent / "web" / "dist"
logger.info(f"Looking for web/dist at: {web_dist}")
logger.info(f"web/dist exists: {web_dist.exists()}")

if web_dist.exists():
    assets_dir = web_dist / "assets"
    logger.info(f"Assets directory: {assets_dir}, exists: {assets_dir.exists()}")
    app.mount("/assets", StaticFiles(directory=str(assets_dir)), name="assets")

    @app.get("/favicon.svg")
    async def favicon():
        return FileResponse(str(web_dist / "favicon.svg"))

    @app.get("/sample.epub")
    async def sample():
        return FileResponse(str(web_dist / "sample.epub"))

    # Serve index.html for all other routes (SPA)
    # This catch-all MUST be registered AFTER API routes to avoid conflicts
    @app.get("/{full_path:path}")
    async def serve_spa(full_path: str):
        # Don't intercept API routes
        if full_path.startswith("api/"):
            from fastapi import HTTPException

            raise HTTPException(status_code=404, detail="Not found")
        return FileResponse(str(web_dist / "index.html"))

    logger.info("Frontend routes registered successfully")
else:
    logger.warning(f"Frontend not built! web/dist does not exist at {web_dist}")

    @app.get("/")
    async def root():
        return {"error": "Frontend not built. Run: cd web && npm run build"}


_base_lifespan = app.router.lifespan_context


async def _prewarm_local_engines() -> None:
    """Pre-warm local TTS engines so they are ready when Edge-TTS falls back.

    Piper is the local fallback (all languages via ONNX, model downloaded per
    language on demand and cached on /data).
    """
    import asyncio

    await asyncio.sleep(10)  # Let the server fully start first
    try:
        import shutil

        if shutil.which("piper"):
            logger.info("✅ Piper binary available — fallback for all languages incl. pt-BR")
        else:
            logger.warning("⚠️  Piper binary not found in PATH — pt-BR fallback unavailable")
    except Exception as exc:
        logger.warning(f"Piper check failed: {exc}")


@asynccontextmanager
async def _hf_lifespan(app):
    import asyncio

    logger.info("=" * 60)
    logger.info("HF App startup complete!")
    logger.info(f"Web dist path: {web_dist}")
    logger.info(f"Web dist exists: {web_dist.exists()}")
    if web_dist.exists():
        logger.info(f"Files in web/dist: {list(web_dist.iterdir())[:10]}")
    logger.info("=" * 60)
    if _base_lifespan:
        async with _base_lifespan(app):
            # Pre-warm local engines in background so they are ready on first conversion
            asyncio.create_task(_prewarm_local_engines())
            yield
    else:
        asyncio.create_task(_prewarm_local_engines())
        yield


app.router.lifespan_context = _hf_lifespan

if __name__ == "__main__":
    import os

    import uvicorn

    port = int(os.getenv("PORT", 7860))
    logger.info(f"Starting uvicorn on port {port}")
    uvicorn.run(app, host="0.0.0.0", port=port, log_level="info")
