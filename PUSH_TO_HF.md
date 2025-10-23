# 🚀 Deploy para Hugging Face Space

## ✅ Preparado!

A pasta `hf-space-final/` está pronta com todos os arquivos necessários.

## Próximos Passos

### 1. Criar o Space no Hugging Face

1. Acesse: https://huggingface.co/new-space
2. Preencha:
   - **Owner**: `pietro1704`
   - **Space name**: `epub-to-mp3`
   - **License**: MIT
   - **SDK**: Docker
   - **Hardware**: CPU basic (FREE)
   - **Visibility**: Public
3. Clique "Create Space"

### 2. Configurar Git e Push

```bash
cd /Users/pietropugliesi/Developer/Epub-to-Mp3/hf-space-final

# Adicionar remote do HF Space (substitua SEU_USERNAME)
git remote add space https://huggingface.co/spaces/pietro1704/epub-to-mp3

# Push para o Space
git push space main

# Se pedir login:
# 1. Instale: pip install huggingface_hub
# 2. Login: huggingface-cli login
# 3. Cole seu token de: https://huggingface.co/settings/tokens
```

### 3. Aguardar Build

- O HF buildará o Docker (~5-10 min)
- Acompanhe em: https://huggingface.co/spaces/pietro1704/epub-to-mp3/logs

### 4. Acessar seu App

Após o build, acesse:
**https://pietro1704-epub-to-mp3.hf.space**

## 📦 O que está incluído

```
hf-space-final/
├── Dockerfile              # Config Docker
├── README.md               # Descrição do Space
├── hf_app.py              # App principal (FastAPI)
├── requirements-hf.txt     # Dependências Python
├── python_app/            # Backend (conversão TTS)
└── web/dist/              # Frontend React buildado
```

## 🔧 Comandos Úteis

```bash
# Ver logs do build
huggingface-cli repo logs spaces/pietro1704/epub-to-mp3

# Atualizar o Space (após mudanças)
cd hf-space-final
git add .
git commit -m "Update: ..."
git push space main

# Deletar o Space
huggingface-cli repo delete spaces/pietro1704/epub-to-mp3
```

## ✨ Features do App

- ✅ Frontend React completo (mesma UI do `web/`)
- ✅ Backend FastAPI (mesma API do `server.py`)
- ✅ 15 vozes portuguesas (Edge-TTS)
- ✅ Upload EPUB/PDF
- ✅ Download MP3
- ✅ Progress tracking
- ✅ Totalmente funcional

## 🐛 Troubleshooting

### Build falha

Verifique logs e veja se falta alguma dependência em `requirements-hf.txt`

### App não inicia

Porta 7860 deve estar configurada corretamente (já está!)

### Frontend não carrega

Verifique se `web/dist/` tem arquivos

### API não funciona

Verifique logs do Docker no HF Spaces
