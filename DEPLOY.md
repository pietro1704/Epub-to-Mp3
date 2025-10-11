# Deployment Guide

## Architecture

The application consists of two parts:
- **Frontend**: Static React app deployed to Cloudflare Pages
- **Backend**: Python FastAPI server (needs separate hosting)

## Backend Deployment

Deploy `python_app/server.py` to a Python-compatible platform:

### Option 1: Railway
```bash
# Install Railway CLI
npm i -g @railway/cli

# Login and deploy
railway login
railway init
railway up
```

### Option 2: Render
1. Create new Web Service at https://render.com
2. Connect your GitHub repo
3. Build command: `pip install -r python_app/requirements.txt`
4. Start command: `python python_app/server.py`

### Option 3: Fly.io
```bash
# Install Fly CLI
curl -L https://fly.io/install.sh | sh

# Deploy
fly launch
fly deploy
```

### Option 4: Your own server
```bash
# Install dependencies
pip install -r python_app/requirements.txt

# Run with Gunicorn
gunicorn python_app.server:app --workers 4 --worker-class uvicorn.workers.UvicornWorker --bind 0.0.0.0:8000
```

## Frontend Deployment

### 1. Update Backend URL

Edit `wrangler.toml` and replace `https://your-backend-url.com` with your actual backend URL:

```toml
[env.production.vars]
BACKEND_URL = "https://your-backend.railway.app"  # Example for Railway

[env.preview.vars]
BACKEND_URL = "https://your-backend.railway.app"
```

### 2. Deploy to Cloudflare Pages

```bash
# Build the frontend
cd web
npm install
npm run build

# Deploy with Wrangler
npx wrangler pages deploy dist --project-name epub-to-mp3-web

# Or deploy via Cloudflare Dashboard:
# 1. Go to https://dash.cloudflare.com/
# 2. Pages > Create a project
# 3. Connect your Git repository
# 4. Build command: cd web && npm install && npm run build
# 5. Build output directory: web/dist
```

### 3. Set Environment Variables (Dashboard Method)

If deploying via Cloudflare Dashboard:
1. Go to your Pages project settings
2. Environment Variables
3. Add: `BACKEND_URL` = `https://your-backend-url.com`
4. Redeploy

## Testing Locally

```bash
# Terminal 1: Start backend
python python_app/server.py

# Terminal 2: Start frontend
cd web
VITE_API_BASE=http://localhost:8000 npm run dev
```

## CORS Configuration

Update `python_app/server.py` to allow your production frontend domain:

```python
app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://localhost:5173",
        "http://localhost:3000",
        "https://epub-to-mp3-web.pages.dev",  # Add your Cloudflare Pages domain
    ],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
```

## Troubleshooting

### 405 Method Not Allowed
- Check that BACKEND_URL is correctly set in wrangler.toml
- Verify the backend is running and accessible

### 502 Bad Gateway
- Backend is down or unreachable
- Check backend logs for errors
- Verify CORS settings allow your frontend domain

### CORS Errors
- Add your Cloudflare Pages domain to backend CORS origins
- Redeploy backend after changes
