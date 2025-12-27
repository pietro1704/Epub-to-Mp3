# Web Frontend

Static frontend for EPUB/PDF to MP3 conversion. Uses real Python backend - **no mocks** (except sample.epub file).

## Batch uploads

Step 1 of the UI now accepts multiple EPUB/PDF files. Drop several books, drag or use the arrow controls to reorder them, then click **Converter** to send everything sequentially while reusing the same engine/voice configuration for every title. During Step 2 you can also drop new files into the inline “Add to queue” card and they will run right after the current conversion.

## Development

### 1. Start Python Backend

```bash
# From project root
cd python_app
python -m uvicorn main:app --reload --port 8000
```

### 2. Start Frontend (in another terminal)

```bash
cd web
npm install
VITE_API_BASE=http://localhost:8000 npm run dev
```

Frontend will run at `http://localhost:5173` and connect to Python backend at `http://localhost:8000`.

**Note**: Without backend running, frontend will show 404 errors. Only `sample.epub` is mocked for file upload testing.

## Build & Deploy

```bash
npm run build
```

Set the environment variable `VITE_API_BASE` to the public URL of your Python backend. The frontend will automatically connect to it.

Example:

```bash
VITE_API_BASE=https://your-backend.example.com npm run build
```

## API Expectations

The frontend expects a Python backend running with these endpoints:

- `POST /api/convert` → accepts `multipart/form-data` with fields `file`, `engine`, optional `voice`, `chapters`. Returns `{ jobId }`.
- `GET /api/jobs/:id` → returns `{ state: "queued" | "running" | "finished" | "failed" | "interrupted", events: string[], outputs: [{ name, url }], error? }`.
- `GET /api/jobs/resumable` → returns list of jobs that can be resumed.

The Python backend implementation is in `python_app/` directory.
