#!/bin/bash
# Copia EPUB de teste de fixtures para web/public (usado em build)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/python_app/tests/fixtures/epubs/test_multifeature.epub"
DEST_DIR="$SCRIPT_DIR/web/public"
DEST_FILE="$DEST_DIR/sample.epub"

echo "📦 Copiando EPUB de teste para public..."

# Verificar se fonte existe
if [ ! -f "$SOURCE" ]; then
    echo "❌ Erro: $SOURCE não encontrado!"
    echo "   Execute este script manualmente para criar o arquivo inicial."
    exit 1
fi

# Criar diretório se não existir
mkdir -p "$DEST_DIR"

# Copiar de fixtures para public
echo "  → Copiando test_multifeature.epub para web/public/sample.epub"
cp "$SOURCE" "$DEST_FILE"

echo "✅ EPUB copiado com sucesso!"
echo ""
echo "Arquivo atualizado:"
ls -lh "$DEST_FILE"
