#!/bin/bash
# Script para subir front + back em paralelo

# Cores para output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}🚀 Iniciando Backend (Python FastAPI)...${NC}"
cd python_app && uvicorn server:app --reload --host 0.0.0.0 --port 8000 &
BACKEND_PID=$!

echo -e "${BLUE}🌐 Iniciando Frontend (Vite)...${NC}"
cd web && VITE_API_BASE=http://localhost:8000 npm run dev &
FRONTEND_PID=$!

# Trap para matar os processos ao sair
trap "kill $BACKEND_PID $FRONTEND_PID 2>/dev/null" EXIT

echo ""
echo -e "${GREEN}✅ Servidores iniciados:${NC}"
echo -e "   Backend:  http://localhost:8000"
echo -e "   Frontend: http://localhost:5173"
echo ""
echo "Pressione Ctrl+C para parar"

# Aguardar
wait
