# Web Frontend

Static frontend scaffold for Cloudflare Pages. It expects a Python conversion API (e.g., Cloudflare Worker proxying to the `python_app` service).

## Development
```bash
cd web
npm install
npm run dev
```
By default the UI calls `/api/*`. During local development point `VITE_API_BASE` to a running backend:
```bash
VITE_API_BASE=http://localhost:8787 npm run dev
```

## Build & Deploy
```bash
npm run build
```
Upload the generated `web/dist` folder to Cloudflare Pages (or configure CI to run `npm install && npm run build`). Set the environment variable `VITE_API_BASE` to the public URL of your backend if it differs from the default `/api` path.

## API Expectations
- `POST /convert` → accepts `multipart/form-data` with fields `file`, `engine`, optional `voice`, `chapters`. Returns `{ jobId }`.
- `GET /jobs/:id` → returns `{ state: "pending" | "running" | "finished" | "failed", events: string[], outputs: [{ name, url }], error? }`.

Implement these endpoints using your preferred hosting (Cloudflare Worker, Fly.io, Dedicated VM) by wrapping the logic inside `python_app`.
