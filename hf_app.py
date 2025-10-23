#!/usr/bin/env python3
"""
Hugging Face Space: EPUB to MP3 Converter
Serves React frontend + FastAPI backend in one app
"""
import sys
from pathlib import Path

# Add python_app to path
sys.path.insert(0, str(Path(__file__).parent / "python_app"))

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse
from python_app.server import app as api_app

# Create main app
app = FastAPI(title="EPUB to MP3 Converter")

# Mount API routes under /api
app.mount("/api", api_app)

# Serve static files from web/dist
web_dist = Path(__file__).parent / "web" / "dist"
if web_dist.exists():
    app.mount("/assets", StaticFiles(directory=str(web_dist / "assets")), name="assets")

    @app.get("/favicon.svg")
    async def favicon():
        return FileResponse(str(web_dist / "favicon.svg"))

    @app.get("/sample.epub")
    async def sample():
        return FileResponse(str(web_dist / "sample.epub"))

    # Serve index.html for all other routes (SPA)
    @app.get("/{full_path:path}")
    async def serve_spa(full_path: str):
        return FileResponse(str(web_dist / "index.html"))
else:
    @app.get("/")
    async def root():
        return {"error": "Frontend not built. Run: cd web && npm run build"}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=7860)
