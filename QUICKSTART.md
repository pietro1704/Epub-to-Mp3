# Quick Start - Full Stack

## Usando Mise (Recomendado)

### Instalação única
```bash
mise install
mise run python:install
mise run web:install
```

### Rodar servidor (1 comando)
```bash
mise run python:server
```

### Rodar frontend (outro terminal)
```bash
mise run web:dev
```

Acesse: http://localhost:5173

## Sem Mise

### Terminal 1: Python Backend
```bash
cd python_app
pip install -r requirements.txt
uvicorn server:app --reload --port 8000
```

### Terminal 2: Frontend
```bash
cd web
npm install
VITE_API_BASE=http://localhost:8000 npm run dev
```

## Endpoints da API

- `POST /api/convert` - Submete conversão
- `GET /api/jobs/{jobId}` - Status da conversão
- `GET /api/outputs/{jobId}/{filename}` - Download do arquivo

## Estrutura

```
python_app/
├── server.py          # FastAPI server (NOVO)
├── main.py            # CLI original
└── src/               # Lógica de conversão

web/
├── src/
│   ├── services/
│   │   └── ConversionService.ts  # Cliente HTTP (sem mocks)
│   └── components/
│       └── DownloadsPanel.tsx    # Player + download ZIP/MP3
└── public/
    └── sample.epub    # Único mock
```

## Fluxo de Desenvolvimento

1. **Frontend envia** arquivo EPUB/PDF para `/api/convert`
2. **Backend processa** em background, atualiza status
3. **Frontend faz polling** em `/api/jobs/{jobId}`
4. **Download** via `/api/outputs/{jobId}/{filename}`

## Conversão Real

O backend está configurado com placeholder. Para conversão real de áudio:

1. Descomente a lógica do `AudioConverter` em `server.py`
2. Configure TTS engine (Edge/Piper/Coqui)
3. Ajuste `process_conversion()` para usar converter real

Atualmente: gera arquivos placeholder em 2s por capítulo para teste rápido.
