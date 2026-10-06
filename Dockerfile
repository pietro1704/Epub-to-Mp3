# Stage 1: Build React frontend
FROM node:26-slim AS frontend-builder

WORKDIR /app/web
COPY web/package*.json ./
RUN npm install --legacy-peer-deps
COPY web/ ./
RUN npm run build

# Stage 2: Build the Rust production server
FROM rust:1-slim-bookworm AS server-builder

WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY crates ./crates
RUN cargo build --release -p converter-server

# Stage 3: Minimal Rust runtime
FROM debian:bookworm-slim

WORKDIR /app

# ffmpeg and libsndfile are required by the conversion pipeline.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    libsndfile1 \
    ca-certificates \
    wget \
    && rm -rf /var/lib/apt/lists/*

COPY --from=server-builder /app/target/release/converter-server /usr/local/bin/converter-server
COPY --from=frontend-builder /app/web/dist ./web/dist

# Hugging Face Spaces persists this root across restarts.
ENV PORT=7860 \
    SPACE_ID=1 \
    PERSISTENT_ROOT=/data/epub-to-mp3
RUN mkdir -p /data/epub-to-mp3/.cache /data/epub-to-mp3/output /data/epub-to-mp3/.uploads /data/epub-to-mp3/.job_inputs

EXPOSE 7860

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:7860/api/health || exit 1

CMD ["/usr/local/bin/converter-server"]
