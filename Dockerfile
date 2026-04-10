# Stage 1: Build React frontend
FROM node:20-slim AS frontend-builder

WORKDIR /app/web
COPY web/package*.json ./
# Use npm install to update dependencies automatically
RUN npm install --legacy-peer-deps
COPY web/ ./
# Build with error output
RUN npm run build || (echo "Frontend build failed!" && exit 1)
# Verify build output
RUN ls -la dist/ && echo "Frontend build successful!"

# Stage 2: Python runtime
FROM python:3.14-slim

WORKDIR /app

# Install system dependencies
# espeak-ng: required by Kokoro TTS for phoneme generation (local neural fallback)
RUN apt-get update && apt-get install -y \
    ffmpeg \
    libsndfile1 \
    espeak-ng \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements first for caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY python_app/ ./python_app/
COPY hf_app.py ./

# Copy built frontend from stage 1
COPY --from=frontend-builder /app/web/dist ./web/dist

# Verify frontend files were copied
RUN ls -la web/dist/ && echo "Frontend files copied successfully"

# Create output directory
RUN mkdir -p /tmp/output

# Expose port for HF Spaces
EXPOSE 7860

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
  CMD python -c "import requests; requests.get('http://localhost:7860/api/health', timeout=5)" || exit 1

# Run the FastAPI server with React frontend
CMD ["python", "-u", "hf_app.py"]
