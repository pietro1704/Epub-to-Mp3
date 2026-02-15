#!/bin/bash
set -euo pipefail

VENV_DIR=".venv"
BIN_DIR="$VENV_DIR/bin"
NATIVE_BIN="$BIN_DIR/piper-native"
PYTHON_SHIM="$BIN_DIR/piper"

if [ ! -d "$VENV_DIR" ]; then
  echo "⚠️  .venv não encontrado; rode 'mise run install' primeiro."
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
    echo "⚠️ Plataforma $PLATFORM/$ARCH não suportada para download automático do Piper."
    exit 0
    ;;
esac

BASE_URL="${PIPER_RELEASE_BASE:-https://github.com/OHF-Voice/piper1-gpl/releases/latest/download}"
DOWNLOAD_URL="${BASE_URL}/${ASSET}"
TMP_FILE="$(mktemp)"

echo "⬇️  Baixando Piper nativo (${ASSET})..."
if curl -L "$DOWNLOAD_URL" -o "$TMP_FILE"; then
  chmod +x "$TMP_FILE"
  mkdir -p "$BIN_DIR"
  mv "$TMP_FILE" "$NATIVE_BIN"
else
  echo "⚠️  Não foi possível baixar ${ASSET}. Verifique sua conexão e rode novamente."
  rm -f "$TMP_FILE"
  exit 0
fi

if [ -x "$PYTHON_SHIM" ] && [ ! -f "${PYTHON_SHIM}-python" ]; then
  mv "$PYTHON_SHIM" "${PYTHON_SHIM}-python"
fi
ln -sf "piper-native" "$PYTHON_SHIM"
echo "✅ Piper nativo instalado em $PYTHON_SHIM"

MODELS_DIR="models"
mkdir -p "$MODELS_DIR"
MODEL_FILE="$MODELS_DIR/pt_BR-faber-medium.onnx"
CONFIG_FILE="$MODELS_DIR/pt_BR-faber-medium.onnx.json"

if [ ! -f "$MODEL_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
  echo "⬇️  Baixando modelo padrão do Piper (pt_BR-faber-medium)..."
  MODEL_BASE="${PIPER_MODEL_BASE:-https://huggingface.co/rhasspy/piper-voices/resolve/main/pt}"
  if curl -L "${MODEL_BASE}/pt_BR-faber-medium.onnx" -o "$MODEL_FILE" \
     && curl -L "${MODEL_BASE}/pt_BR-faber-medium.onnx.json" -o "$CONFIG_FILE"; then
    echo "✅ Modelo salvo em $MODEL_FILE"
  else
    echo "⚠️  Falha ao baixar o modelo padrão. Baixe manualmente e coloque em $MODELS_DIR."
  fi
else
  echo "ℹ️  Modelo pt_BR-faber-medium já existente."
fi
