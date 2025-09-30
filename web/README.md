# Web Frontend

Static frontend for EPUB/PDF to MP3 conversion. Uses real Python backend - **no mocks** (except sample.epub file).

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
Upload the generated `web/dist` folder to Cloudflare Pages (or configure CI to run `npm install && npm run build`). Set the environment variable `VITE_API_BASE` to the public URL of your backend if it differs from the default `/api` path.

## API Expectations
- `POST /convert` → accepts `multipart/form-data` with fields `file`, `engine`, optional `voice`, `chapters`. Returns `{ jobId }`.
- `GET /jobs/:id` → returns `{ state: "pending" | "running" | "finished" | "failed", events: string[], outputs: [{ name, url }], error? }`.

Implement these endpoints using your preferred hosting (Cloudflare Worker, Fly.io, Dedicated VM) by wrapping the logic inside `python_app`.
