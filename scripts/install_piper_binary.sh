#!/bin/bash
set -euo pipefail

VENV_DIR=".venv"
BIN_DIR="$VENV_DIR/bin"
NATIVE_BIN="$BIN_DIR/piper-native"
PYTHON_SHIM="$BIN_DIR/piper"

if [ ! -d "$VENV_DIR" ]; then
  echo "⚠️  .venv not found; run 'mise run install' first."
  exit 0
fi

PLATFORM="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

case "$PLATFORM" in
  darwin)
    if [ "$ARCH" = "arm64" ]; then
      ASSET="piper-mac-arm64"
    else
      ASSET="piper-mac-x64"
    fi
    ;;
  linux)
    if [ "$ARCH" = "aarch64" ]; then
      ASSET="piper-linux-arm64"
    else
      ASSET="piper-linux-x64"
    fi
    ;;
  *)
    echo "⚠️ Platform $PLATFORM/$ARCH not supported for automatic Piper download."
    exit 0
    ;;
esac

BASE_URL="${PIPER_RELEASE_BASE:-https://github.com/OHF-Voice/piper1-gpl/releases/latest/download}"
DOWNLOAD_URL="${BASE_URL}/${ASSET}"
TMP_FILE="$(mktemp)"

echo "⬇️  Downloading native Piper (${ASSET})..."
HTTP_CODE=$(curl -L -w "%{http_code}" "$DOWNLOAD_URL" -o "$TMP_FILE" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ] && [ -s "$TMP_FILE" ]; then
  # Validate the downloaded file is a real binary, not an HTML error page
  FILE_TYPE=$(file -b "$TMP_FILE" 2>/dev/null || echo "unknown")
  if echo "$FILE_TYPE" | grep -qiE "executable|Mach-O|ELF|script"; then
    chmod +x "$TMP_FILE"
    mkdir -p "$BIN_DIR"
    mv "$TMP_FILE" "$NATIVE_BIN"

    if [ -x "$PYTHON_SHIM" ] && [ ! -f "${PYTHON_SHIM}-python" ]; then
      mv "$PYTHON_SHIM" "${PYTHON_SHIM}-python"
    fi
    ln -sf "piper-native" "$PYTHON_SHIM"
    echo "✅ Native Piper installed at $PYTHON_SHIM"
  else
    echo "⚠️  Downloaded file is not a valid binary (got: $FILE_TYPE). Keeping pip piper."
    rm -f "$TMP_FILE"
  fi
else
  echo "⚠️  Could not download ${ASSET} (HTTP $HTTP_CODE). Keeping pip piper."
  rm -f "$TMP_FILE"
fi

MODELS_DIR="models"
mkdir -p "$MODELS_DIR"
MODEL_FILE="$MODELS_DIR/pt_BR-faber-medium.onnx"
CONFIG_FILE="$MODELS_DIR/pt_BR-faber-medium.onnx.json"

if [ ! -f "$MODEL_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
  echo "⬇️  Downloading default Piper model (pt_BR-faber-medium)..."
  MODEL_BASE="${PIPER_MODEL_BASE:-https://huggingface.co/rhasspy/piper-voices/resolve/main/pt}"
  if curl -fL "${MODEL_BASE}/pt_BR-faber-medium.onnx" -o "$MODEL_FILE" \
     && curl -fL "${MODEL_BASE}/pt_BR-faber-medium.onnx.json" -o "$CONFIG_FILE"; then
    echo "✅ Model saved to $MODEL_FILE"
  else
    echo "⚠️  Failed to download default model. Download manually to $MODELS_DIR."
  fi
else
  echo "ℹ️  Model pt_BR-faber-medium already present."
fi
