# Deploy para Hugging Face Spaces

## ✅ Testado Localmente

O app funciona perfeitamente em local:
- **Frontend React**: http://localhost:7860/
- **API Backend**: http://localhost:7860/api/
- **Docs API**: http://localhost:7860/api/docs

## 📦 Arquivos para HF Space

Certifique-se que estes arquivos estão commitados:

```
/
├── hf_app.py              # App principal (FastAPI + static files)
├── requirements-hf.txt    # Dependências Python
├── Dockerfile.hf          # Docker config
├── README_HF.md           # README do Space (renomear para README.md no HF)
├── python_app/            # Backend Python
│   ├── src/
│   └── server.py
└── web/dist/              # Frontend React buildado
    ├── index.html
    ├── assets/
    └── favicon.svg
```

## 🚀 Steps para Deploy

### 1. Build Frontend (se ainda não fez)

```bash
cd web
npm install
npm run build
cd ..
```

### 2. Criar Space no Hugging Face

1. Acesse https://huggingface.co/new-space
2. Nome: `epub-to-mp3-converter`
3. SDK: **Docker**
4. Hardware: **CPU basic** (grátis)

### 3. Clone o Space Localmente

```bash
git clone https://huggingface.co/spaces/SEU_USERNAME/epub-to-mp3-converter hf-space-repo
cd hf-space-repo
```

### 4. Copiar Arquivos Necessários

```bash
# Copiar arquivos do projeto
cp ../hf_app.py .
cp ../requirements-hf.txt .
cp ../Dockerfile.hf ./Dockerfile
cp ../README_HF.md ./README.md

# Copiar backend
cp -r ../python_app .

# Copiar frontend buildado
mkdir -p web
cp -r ../web/dist web/
```

### 5. Commit e Push

```bash
git add .
git commit -m "Initial deploy: React frontend + FastAPI backend"
git push
```

### 6. Aguardar Build

O Hugging Face vai:
1. Ler o Dockerfile
2. Buildar a imagem Docker
3. Iniciar o app na porta 7860
4. Tornar disponível em: `https://huggingface.co/spaces/SEU_USERNAME/epub-to-mp3-converter`

## 🔧 Configuração do Dockerfile

O `Dockerfile.hf` está configurado para:
- Base: Python 3.11-slim
- Instalar ffmpeg (necessário para conversão de áudio)
- Copiar backend (python_app)
- Copiar frontend (web/dist)
- Rodar hf_app.py na porta 7860

## 📊 Estrutura da Aplicação

```
hf_app.py
├── / (root)         → Serve web/dist/index.html (React SPA)
├── /api/*           → FastAPI backend (conversão, jobs, downloads)
└── /assets/*        → Static files (JS, CSS, images)
```

## 🐛 Troubleshooting

### Build falha

Verifique logs no HF Space e veja se:
- `web/dist` existe e tem arquivos
- `requirements-hf.txt` tem todas dependências
- `python_app/src/` existe

### App não inicia

Cheque porta 7860 no Dockerfile e hf_app.py

### Frontend carrega mas API não funciona

Verifique se `/api` está montado corretamente em `hf_app.py`

### Conversão falha

Certifique-se que ffmpeg está instalado no Dockerfile

## ✨ Features

- ✅ Frontend React completo (mesma UI do web/)
- ✅ Backend FastAPI (mesma API do server.py)
- ✅ TTS Edge (15 vozes PT-BR)
- ✅ Upload de EPUB/PDF
- ✅ Download de MP3s
- ✅ Progress tracking
- ✅ Totalmente funcional em HF Spaces

## 🔐 Limitações do HF Spaces (FREE tier)

- **CPU only** (sem GPU)
- **Timeout**: 60 minutos por request
- **Storage**: Ephemeral (arquivos deletados após restart)
- **Concurrent users**: Limitado

Para arquivos grandes, considere HF Spaces PRO ou deploy em Railway/Render.
