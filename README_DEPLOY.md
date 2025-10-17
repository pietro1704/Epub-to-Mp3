# 🚀 Deploy - Configuração Rápida

## 📦 O que você já tem

✅ Backend Python (FastAPI) - `python_app/server.py`  
✅ Frontend React - `web/`  
✅ Bot Telegram - `python_app/telegram_bot.py`  
✅ Configurações de deploy prontas

## 🎯 Cenário 1: Web App (Railway + Cloudflare)

```
┌─────────────────────┐
│  Usuário Browser    │
└──────────┬──────────┘
           │
           ↓
┌─────────────────────┐     POST /api/convert      ┌─────────────────────┐
│ Cloudflare Pages    │ ────────────────────────→  │ Railway             │
│ (Frontend estático) │                            │ (Backend Python)    │
│ seu-app.pages.dev   │ ←──────────────────────    │ *.railway.app       │
└─────────────────────┘     JSON + MP3 URLs       └─────────────────────┘
```

**Status Atual**: ❌ Erro 405 porque `VITE_API_BASE` não está configurada

### 🔧 Solução

Ver: **[FIX_405_ERROR.md](./FIX_405_ERROR.md)** (solução em 3 passos)

## 🤖 Cenário 2: Bot Telegram

```
┌─────────────────────┐
│  Usuário Telegram   │
└──────────┬──────────┘
           │ Envia EPUB
           ↓
┌─────────────────────┐
│ Railway             │
│ telegram_bot.py     │  ← Roda 24/7
│ + converter.py      │
│ + Edge-TTS          │
└──────────┬──────────┘
           │ Envia MP3s
           ↓
┌─────────────────────┐
│  Usuário Telegram   │
└─────────────────────┘
```

**Vantagens**: Setup mais simples, UX melhor para leigos

### 🔧 Setup

```bash
# 1. Criar bot no @BotFather
# 2. Railway > Variables:
TELEGRAM_BOT_TOKEN=123456789:ABC...

# 3. Editar Procfile para usar bot:
bot: cd python_app && python telegram_bot.py
```

## 📁 Arquivos Importantes

```
Epub-to-Mp3/
├── 📘 FIX_405_ERROR.md          ← **LER PRIMEIRO** (solução erro 405)
├── 📗 DEPLOY.md                  ← Guia completo de deploy
├── 📙 README_DEPLOY.md           ← Este arquivo (visão geral)
├── 
├── Procfile                      ← Railway: como rodar o app
├── railway.json                  ← Railway: configuração de build
├── nixpacks.toml                 ← Railway: Python + ffmpeg
├── .env.example                  ← Variáveis de ambiente (copiar para .env)
│
├── python_app/
│   ├── server.py                 ← Backend FastAPI (Web App)
│   ├── telegram_bot.py           ← Bot Telegram
│   ├── requirements.txt          ← Dependências Python
│   └── src/                      ← Lógica de conversão
│
└── web/
    ├── src/                      ← Frontend React
    ├── .env.local                ← Dev: backend local
    ├── .env.production.example   ← Produção: backend Railway
    └── dist/                     ← Build (após npm run build)
```

## 🎬 Quick Start

### Opção A: Só Web App (Frontend + Backend separados)

1. **Deploy Backend (Railway)**
   ```bash
   # 1. Push no GitHub
   git push
   
   # 2. Railway detecta automaticamente
   # 3. Copiar URL gerada: https://seu-app.railway.app
   ```

2. **Deploy Frontend (Cloudflare)**
   ```bash
   # 1. Conectar repo no Cloudflare Pages
   # 2. Configurar variável: VITE_API_BASE=https://seu-app.railway.app
   # 3. Deploy automático
   ```

3. **Conectar os dois**
   - Railway > Variables: `FRONTEND_URL=https://seu-app.pages.dev`

### Opção B: Só Bot Telegram

1. **Criar bot**: `@BotFather` no Telegram
2. **Railway**: Adicionar `TELEGRAM_BOT_TOKEN`
3. **Editar Procfile**: Mudar de `web:` para `bot:`
4. **Push e deploy**: Railway inicia o bot

### Opção C: Ambos (recomendado)

Railway permite **múltiplos serviços** no mesmo projeto:
- Serviço 1: Web (FastAPI)
- Serviço 2: Bot (Telegram)

Ambos compartilham o mesmo código!

## ❓ FAQ

### Qual opção é melhor?

| Critério | Web App | Bot Telegram |
|----------|---------|--------------|
| Setup | Médio | Fácil |
| UX Leigo | Boa | **Excelente** |
| Limite Upload | Configurável | 50MB |
| Custo | Grátis (500h/mês) | Grátis (ilimitado) |

**Recomendação**: Comece com **Bot Telegram**, adicione Web App depois se precisar.

### Como testar localmente?

```bash
# Backend
cd python_app
uvicorn server:app --reload

# Frontend (em outro terminal)
cd web
VITE_API_BASE=http://localhost:8000 npm run dev

# Bot Telegram (em outro terminal)
export TELEGRAM_BOT_TOKEN=seu_token
python python_app/telegram_bot.py
```

### Erro 405 no Cloudflare?

**Leia**: [FIX_405_ERROR.md](./FIX_405_ERROR.md)

**TL;DR**: Frontend precisa saber onde está o backend!

```bash
# Cloudflare Pages > Environment variables
VITE_API_BASE=https://seu-backend.railway.app
```

### Quanto custa?

- **Railway**: $5 grátis/mês (~500 horas)
- **Cloudflare Pages**: 100% grátis (ilimitado)
- **Telegram Bot**: 100% grátis (ilimitado)

**Total**: Grátis para uso pessoal 🎉

## 📚 Próximos Passos

1. ✅ Ler [FIX_405_ERROR.md](./FIX_405_ERROR.md) se tiver erro 405
2. ✅ Seguir [DEPLOY.md](./DEPLOY.md) para deploy completo
3. ✅ Testar localmente antes do deploy
4. ✅ Monitorar logs no Railway Dashboard

## 🆘 Problemas?

1. Verificar [DEPLOY.md - Troubleshooting](./DEPLOY.md#-troubleshooting)
2. Verificar logs no Railway
3. Abrir issue no GitHub

---

**Pronto para deploy?** → [FIX_405_ERROR.md](./FIX_405_ERROR.md) (se erro 405) ou [DEPLOY.md](./DEPLOY.md) (setup completo)
