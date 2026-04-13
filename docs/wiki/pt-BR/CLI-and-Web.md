# Uso via CLI e Web

## CLI

Ative o ambiente virtual antes de converter localmente:

```bash
source .venv/bin/activate
```

### Comandos comuns

Conversão básica:

```bash
python -m python_app.main convert livro.epub
```

Forçar engine:

```bash
python -m python_app.main convert livro.epub --engine edge
python -m python_app.main convert livro.epub --engine piper
```

Capítulo único:

```bash
python -m python_app.main convert livro.epub --chapter 3
```

Faixa ou seleção:

```bash
python -m python_app.main convert livro.epub --chapter 5.1,5.2,5.3
```

Pré-visualizar estrutura:

```bash
python -m python_app.main convert livro.epub --show-structure
```

Ignorar cache:

```bash
python -m python_app.main convert livro.epub --clear-cache
```

Batch:

```bash
python -m python_app.main convert livro1.epub livro2.pdf --batch ~/pasta/
```

## Servidor web

Subir backend:

```bash
mise run web
```

Ou diretamente:

```bash
uvicorn python_app.server:app --port 8000
```

Para Hugging Face Spaces:

```bash
python hf_app.py
```

## Frontend

Desenvolvimento:

```bash
cd web && npm run dev
```

Build:

```bash
cd web && npm run build
```

## API principal

- `POST /api/convert`: envia arquivo e inicia conversão
- `GET /api/jobs/{job_id}`: estado do job
- `POST /api/jobs/{job_id}/cancel`: cancela um job
- `GET /api/outputs/{job_id}/{filename}`: baixa MP3 ou ZIP
- `GET /api/voices`: lista de vozes
- `GET /api/telemetry`: métricas agregadas
- `GET /api/health`: health check

## Limites de upload

Padrão: `100 MB`

Sobrescreva com:

```bash
export MAX_UPLOAD_MB=200
export VITE_MAX_UPLOAD_MB=200
```
