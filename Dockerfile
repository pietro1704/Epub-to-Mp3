# Stage 1: Build React frontend
FROM node:26.13.1-slim AS frontend-builder

WORKDIR /app/web
COPY web/package*.json ./
RUN npm install --global npm@12.2.2 && npm ci --no-audit --no-fund
COPY web/ ./
RUN npm run build

# Stage 2: Build the Rust production server
# The prebuilt ONNX Runtime that `ort` links statically needs glibc >= 2.38 and a
# GCC 13 libstdc++; Debian bookworm (glibc 2.36) cannot link or run it. Keep the
# builder and the runtime stage on the same Debian release.
FROM rust:1-slim-trixie AS server-builder

# The embedded Piper runtime compiles the vendored eSpeak NG phonemizer; its
# CMake build clones sonic with git, so git and CA certificates are required.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    clang \
    cmake \
    g++ \
    git \
    libclang-dev \
    make \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY crates ./crates
COPY native ./native
COPY benches ./benches
# Ship the phoneme data produced by this exact phonemizer build; a distribution
# package may carry an incompatible data version. Voice models are never built in.
RUN cargo build --locked --release -p converter-server \
    && cp -R "$(find target/release/build -type d -path '*/espeak-rs-sys*/out/share/espeak-ng-data' | head -n 1)" /app/espeak-ng-data \
    && test -f /app/espeak-ng-data/phontab

# Stage 3: Minimal Rust runtime
FROM debian:trixie-slim

WORKDIR /app

# Audio decoding, encoding and tagging run in process in converter-core.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Hugging Face Spaces runs the container as UID 1000.
RUN useradd --create-home --uid 1000 user

COPY --from=server-builder /app/target/release/converter-server /usr/local/bin/converter-server
COPY --from=server-builder /app/espeak-ng-data /usr/local/share/epub-to-mp3/espeak-ng-data
COPY --from=frontend-builder /app/web/dist ./web/dist

# This root survives restarts only when storage is attached at /data, which
# exists at runtime, not during the build. Without it the server starts empty
# and downloads a missing voice model again when a conversion needs it.
ENV PORT=7860 \
    HOST=0.0.0.0 \
    SPACE_ID=1 \
    HOME=/home/user \
    PERSISTENT_ROOT=/data/epub-to-mp3 \
    ESPEAK_DATA_DIRECTORY=/usr/local/share/epub-to-mp3
RUN install -d -o user -g user /data/epub-to-mp3 /data/epub-to-mp3/.cache /data/epub-to-mp3/output \
    /data/epub-to-mp3/.uploads /data/epub-to-mp3/.job_inputs

USER user

EXPOSE 7860

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:7860/api/health || exit 1

CMD ["/usr/local/bin/converter-server"]
