# CLI and Web Usage

## CLI

Activate the virtual environment before local conversion:

```bash
source .venv/bin/activate
```

### Common commands

Basic conversion:

```bash
python -m python_app.main convert book.epub
```

Force a specific engine:

```bash
python -m python_app.main convert book.epub --engine edge
python -m python_app.main convert book.epub --engine piper
```

Single chapter:

```bash
python -m python_app.main convert book.epub --chapter 3
```

Range or selection:

```bash
python -m python_app.main convert book.epub --chapter 5.1,5.2,5.3
```

Preview structure:

```bash
python -m python_app.main convert book.epub --show-structure
```

Ignore cache:

```bash
python -m python_app.main convert book.epub --clear-cache
```

Batch:

```bash
python -m python_app.main convert book1.epub book2.pdf --batch ~/folder/
```

## Web server

Start the backend:

```bash
mise run web
```

Or directly:

```bash
uvicorn python_app.server:app --port 8000
```

For Hugging Face Spaces:

```bash
python hf_app.py
```

## Frontend

Development:

```bash
cd web && npm run dev
```

Build:

```bash
cd web && npm run build
```

## Main API

- `POST /api/convert`: upload a file and start conversion
- `GET /api/jobs/{job_id}`: job status
- `POST /api/jobs/{job_id}/cancel`: cancel a job
- `GET /api/outputs/{job_id}/{filename}`: download MP3 or ZIP
- `GET /api/voices`: curated voice list
- `GET /api/telemetry`: aggregated metrics
- `GET /api/health`: health check
