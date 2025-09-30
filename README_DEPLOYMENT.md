# Deployment Guide

## Local Development

### Prerequisites
- [mise](https://mise.jdx.dev/) installed
- Python 3.11+
- Node 20+

### Quick Start

```bash
# Install dependencies
mise run python:install
mise run web:install

# Start both frontend and backend
mise run dev
# Or use the shell script
./dev.sh

# Access:
# - Backend: http://localhost:8000
# - Frontend: http://localhost:5173
```

### Individual Services

```bash
# Backend only
mise run python:server

# Frontend only
mise run web:dev

# Run tests
mise run python:test
mise run web:test
```

## Production Deployment

### Frontend (Cloudflare Pages)

Already configured in `wrangler.toml`:

```bash
cd web
npm run build
npx wrangler pages deploy dist
```

### Backend Options

The Python backend needs to be deployed separately. Options:

#### Option 1: Railway

1. Create account at [railway.app](https://railway.app)
2. Connect GitHub repo
3. Set root directory: `python_app`
4. Set start command: `uvicorn server:app --host 0.0.0.0 --port $PORT`
5. Add environment variables if needed
6. Deploy
7. Update `.env.production` with Railway URL

#### Option 2: Render

1. Create account at [render.com](https://render.com)
2. New Web Service from GitHub
3. Root directory: `python_app`
4. Build command: `pip install -r requirements.txt`
5. Start command: `uvicorn server:app --host 0.0.0.0 --port $PORT`
6. Deploy
7. Update `.env.production` with Render URL

#### Option 3: Fly.io

```bash
cd python_app
fly launch
fly deploy
```

Update `.env.production` with Fly.io URL.

### Update Production Config

After backend deployment:

1. Edit `web/.env.production`
2. Set `VITE_API_BASE=https://your-backend-url.com`
3. Rebuild and redeploy frontend:
   ```bash
   cd web
   npm run build
   npx wrangler pages deploy dist
   ```

## Environment Variables

### Local (`.env.local`)
```env
VITE_API_BASE=http://localhost:8000
```

### Production (`.env.production`)
```env
VITE_API_BASE=https://your-backend-url.com
```
