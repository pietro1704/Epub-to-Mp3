# Stage 1: Build React frontend
FROM node:20-slim AS frontend-builder

WORKDIR /app/web
COPY web/package*.json ./
# Usar npm install para atualizar dependências automaticamente
RUN npm install --legacy-peer-deps
COPY web/ ./
RUN npm run build

# Stage 2: Python runtime
FROM python:3.11-slim

WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y \
    ffmpeg \
    libsndfile1 \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements first for caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY python_app/ ./python_app/
COPY hf_app.py ./

# Copy built frontend from stage 1
COPY --from=frontend-builder /app/web/dist ./web/dist

# Create output directory
RUN mkdir -p /tmp/output

# Expose port for HF Spaces
EXPOSE 7860

# Run the FastAPI server with React frontend
CMD ["python", "hf_app.py"]
