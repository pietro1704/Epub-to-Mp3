# 📦 Guia de Deploy - EPUB to MP3 Converter

Este guia contém instruções completas para deploy do projeto em produção usando **Railway + Cloudflare Pages** ou **Bot Telegram**.

---

## 🌐 Opção 1: Web App (Railway + Cloudflare Pages)

### Arquitetura
```
Frontend (Cloudflare Pages) → API REST → Backend Python (Railway)
      └─ web/dist                          └─ server.py (FastAPI)
                                              └─ Edge-TTS
```

### 📋 Pré-requisitos
- Conta no [Railway](https://railway.app) (grátis)
- Conta no [Cloudflare](https://pages.cloudflare.com) (grátis)
- Conta no [GitHub](https://github.com)

---

## 🚂 PARTE 1: Deploy Backend (Railway)

### 1.1 Criar Projeto no Railway

1. Acesse [railway.app](https://railway.app) e faça login
2. Clique em **"New Project"**
3. Selecione **"Deploy from GitHub repo"**
4. Autorize o Railway a acessar seu repositório
5. Selecione este repositório: `Epub-to-Mp3`

### 1.2 Configurar Variáveis de Ambiente

No painel do Railway, vá em **Variables** e adicione:

```bash
# Frontend URL (você vai obter após deploy no Cloudflare)
FRONTEND_URL=https://seu-app.pages.dev

# Opcional: domínio do Cloudflare Pages (auto-configurado)
CLOUDFLARE_PAGES_URL=https://seu-app.pages.dev
```

### 1.3 Deploy Automático

O Railway vai automaticamente:
- ✅ Detectar que é um projeto Python
- ✅ Ler o `nixpacks.toml` para configuração
- ✅ Instalar dependências do `requirements.txt`
- ✅ Executar o comando do `Procfile` (uvicorn)

**Deploy leva ~3-5 minutos na primeira vez**

### 1.4 Obter URL do Backend

Após o deploy:
1. Vá na aba **"Settings" > "Networking"**
2. Clique em **"Generate Domain"**
3. Copie a URL gerada (ex: `https://seu-app-production.up.railway.app`)

---

## ☁️ PARTE 2: Deploy Frontend (Cloudflare Pages)

### 2.1 Preparar Build

No diretório `web/`, configure a URL da API do backend:

```bash
cd web

# Criar arquivo de configuração (opcional, pode usar variável de ambiente)
echo "VITE_API_BASE=https://seu-app-production.up.railway.app" > .env.production
```

### 2.2 Build Local (Teste)

```bash
# Instalar dependências
npm install

# Testar localmente com backend Railway
VITE_API_BASE=https://seu-app-production.up.railway.app npm run dev

# Build para produção
npm run build
```

Saída: arquivos estáticos em `web/dist/`

### 2.3 Deploy no Cloudflare Pages

#### Opção A: Via GitHub (Recomendado)

1. Acesse [dash.cloudflare.com](https://dash.cloudflare.com)
2. Vá em **"Workers & Pages" > "Create application"**
3. Selecione **"Pages" > "Connect to Git"**
4. Autorize e selecione o repositório `Epub-to-Mp3`
5. Configure:
   - **Build command**: `cd web && npm run build`
   - **Build output directory**: `web/dist`
   - **Root directory**: `/` (raiz do projeto)
6. Adicione variável de ambiente:
   - `VITE_API_BASE` = `https://seu-app-production.up.railway.app`
7. Clique em **"Save and Deploy"**

#### Opção B: Via CLI (Wrangler)

```bash
# Instalar Wrangler CLI
npm install -g wrangler

# Login no Cloudflare
wrangler login

# Deploy direto
cd web
npm run build
wrangler pages deploy dist --project-name=epub-to-mp3
```

### 2.4 Obter URL do Frontend

Após deploy, Cloudflare fornece:
- URL de produção: `https://epub-to-mp3.pages.dev`
- Cada commit gera preview: `https://abc123.epub-to-mp3.pages.dev`

### 2.5 Atualizar Backend com URL do Frontend

Volte no **Railway > Variables** e atualize:

```bash
FRONTEND_URL=https://epub-to-mp3.pages.dev
CLOUDFLARE_PAGES_URL=https://epub-to-mp3.pages.dev
```

Railway fará redeploy automático (~1 min).

---

## ☁️ PARTE 3 (Opcional): Cloudflare R2 Storage

**Por que precisar de R2?**
- Railway tem storage efêmero (arquivos deletados após restart)
- Livros grandes (100-400 MB) precisam de storage persistente
- R2 = **10 GB grátis** + unlimited egress

### 3.1 Criar Bucket R2

1. Acesse [dash.cloudflare.com](https://dash.cloudflare.com) > **R2**
2. Clique em **"Create bucket"**
3. Nome: `epub-to-mp3` (ou qualquer nome)
4. Localização: **Automatic**
5. Clique em **"Create bucket"**

### 3.2 Gerar API Token

1. No painel R2, clique em **"Manage R2 API Tokens"**
2. Clique em **"Create API Token"**
3. Nome: `epub-to-mp3-api`
4. Permissões: **Admin Read & Write**
5. TTL: **Forever** (ou conforme preferir)
6. Clique em **"Create API Token"**

Copie e salve:
- **Access Key ID**
- **Secret Access Key**
- **Account ID** (no painel R2, lado direito)

### 3.3 Configurar Public URL (Opcional)

Para URLs públicas sem presigned URL:

1. No bucket, vá em **"Settings" > "Public Access"**
2. Ative **"Allow Access"**
3. Copie a URL pública: `https://pub-xxxxx.r2.dev`

**Ou** configure custom domain:
1. R2 > Bucket > Settings > **Connect domain**
2. Adicione: `files.seudominio.com`
3. Siga instruções para DNS

### 3.4 Configurar Railway com R2

No Railway > Variables, adicione:

```bash
# R2 credentials
R2_ACCOUNT_ID=abc123def456
R2_ACCESS_KEY_ID=your_access_key_id
R2_SECRET_ACCESS_KEY=your_secret_access_key
R2_BUCKET_NAME=epub-to-mp3

# Public URL (se configurou)
R2_PUBLIC_URL=https://pub-xxxxx.r2.dev
# ou
R2_PUBLIC_URL=https://files.seudominio.com
```

Railway fará redeploy automático. Os arquivos agora serão salvos no R2!

### 3.5 Configurar Cleanup Automático

Para limpar arquivos antigos automaticamente:

1. No GitHub, vá em **Settings > Secrets > Actions**
2. Adicione secret:
   - **Name**: `API_URL`
   - **Value**: `https://seu-app.railway.app` (URL do backend Railway)
3. O workflow `.github/workflows/cleanup.yml` rodará automaticamente a cada 6 horas

**Ou** teste manualmente:
```bash
# GitHub > Actions > Cleanup Old Files > Run workflow
```

---

## ✅ Verificar Deploy Web

1. Acesse o frontend: `https://epub-to-mp3.pages.dev`
2. Teste upload de um arquivo EPUB pequeno
3. Verifique conversão e download do MP3

**Logs:**
- Backend: Railway Dashboard > Deployments > View Logs
- Frontend: Cloudflare Dashboard > Pages > View Logs

---

## 🤖 Opção 2: Bot Telegram

### Arquitetura
```
Telegram → Bot API → Python (telegram_bot.py)
                      └─ Edge-TTS + Converter
```

### 📋 Pré-requisitos
- Conta Telegram
- Token do bot (via @BotFather)

---

## 📱 PARTE 1: Criar Bot no Telegram

### 1.1 Obter Token do Bot

1. Abra o Telegram e busque por **@BotFather**
2. Envie `/newbot`
3. Escolha um nome: `EPUB to MP3 Converter`
4. Escolha um username: `epub_to_mp3_bot` (deve terminar em `_bot`)
5. Copie o **token** fornecido (ex: `123456789:ABCdefGHIjklMNOpqrsTUVwxyz`)

### 1.2 Configurar Bot

Ainda no @BotFather:

```
/setdescription - Conversor de EPUB/PDF para Audiobook MP3
/setabouttext - Transforme ebooks em audiobooks com vozes naturais PT-BR
/setcommands - Configure comandos:
  start - Iniciar conversão
  help - Ajuda
  cancel - Cancelar operação
```

---

## 🚂 PARTE 2: Deploy Bot no Railway

### 2.1 Configurar Variáveis de Ambiente

No Railway, adicione:

```bash
# Token do bot Telegram
TELEGRAM_BOT_TOKEN=123456789:ABCdefGHIjklMNOpqrsTUVwxyz
```

### 2.2 Atualizar Procfile

Edite o arquivo `Procfile`:

```bash
# Descomente a linha do bot:
bot: cd python_app && python telegram_bot.py
```

**Ou**, crie um **serviço separado** no Railway:
- Crie novo serviço no mesmo projeto
- Use o mesmo repositório
- Altere variável `START_COMMAND` para rodar o bot

### 2.3 Deploy

Railway fará deploy automático. Verifique logs:

```
Bot iniciado!
INFO:telegram.ext.Application:Application started
```

---

## ✅ Verificar Deploy Bot

1. Abra o Telegram
2. Busque por `@seu_bot_username`
3. Envie `/start`
4. Teste enviando um arquivo EPUB pequeno
5. Escolha voz e configure opções
6. Receba os MP3s gerados

---

## 🔧 Troubleshooting

### ❌ Erro 405: "Backend responded with status 405"

**Sintoma**: Frontend carregou mas ao enviar arquivo aparece erro 405

**Causa**: Frontend está tentando acessar `/api/convert` no próprio domínio do Cloudflare (que não tem backend)

**Solução**:
1. **No Cloudflare Pages**, configure a variável de ambiente:
   ```
   VITE_API_BASE=https://seu-app-production.up.railway.app
   ```
2. **Redeploy** (Cloudflare Pages > Deployments > Retry deployment)
3. **Verificar**: Abra DevTools (F12) > Network e veja se a requisição vai para o Railway

**Como verificar se está correto:**
```javascript
// No console do navegador (F12):
console.log(window.location.origin); // https://seu-app.pages.dev
// A requisição deve ir para Railway, NÃO para o mesmo domínio!
```

### Railway: Build Failed

**Problema**: Falha ao instalar dependências

**Solução**:
```bash
# Verificar requirements.txt
pip install -r python_app/requirements.txt

# Se houver conflitos, rodar:
python resolve_dependencies.py
```

### Cloudflare: Build Failed

**Problema**: Build do frontend falha

**Solução**:
1. Verificar logs no Cloudflare Dashboard
2. Conferir se `VITE_API_BASE` está configurada
3. Testar build local:
   ```bash
   cd web
   VITE_API_BASE=https://seu-backend.railway.app npm run build
   ```

### CORS Error no Frontend

**Problema**: `Access-Control-Allow-Origin` error

**Solução**:
1. Verificar que `FRONTEND_URL` está configurada no Railway:
   ```
   FRONTEND_URL=https://seu-app.pages.dev
   ```
2. Verificar logs do backend no Railway (deve mostrar o domínio permitido)

### Bot Telegram: Timeout

**Problema**: Bot não responde

**Solução**:
```bash
# Verificar logs no Railway
# Verificar token está correto
# Testar localmente:
export TELEGRAM_BOT_TOKEN=seu_token
python python_app/telegram_bot.py
```

---

## 📏 Limites e Boas Práticas

### Tamanhos de Arquivo

| Plataforma | Limite | Solução |
|------------|--------|---------|
| **Telegram Bot** | 50 MB/arquivo | Compressão 8k bitrate (~3.6 MB/hora) |
| **Railway** | Storage efêmero | Upload para R2 após conversão |
| **Cloudflare R2** | 10 GB grátis | Cleanup automático (48h) |

### Estimativas de Tamanho (8k bitrate)

| Duração | Tamanho Áudio | Observação |
|---------|--------------|------------|
| 1 hora | ~3.6 MB | ✅ Cabe no Telegram |
| 5 horas | ~18 MB | ✅ Cabe no Telegram |
| 10 horas | ~36 MB | ✅ Cabe no Telegram |
| 15 horas | ~54 MB | ❌ Excede limite Telegram |
| 20 horas | ~72 MB | ❌ Usar Web App com R2 |

**Livro médio (300 páginas)**: ~10 horas = **36 MB** ✅

### Boas Práticas

#### 1. Use Compressão Otimizada

```python
# Configuração padrão (já implementada)
config = ConversionConfig(
    bitrate="8k",        # 8 kbps - boa qualidade para voz
    sample_rate=16_000,  # 16 kHz - suficiente para fala
    channels=1,          # Mono - audiobooks não precisam stereo
)
```

**Não use bitrates maiores** a menos que qualidade seja crítica:
- 16k = 2x maior (~7.2 MB/hora) - pode exceder limite Telegram
- 32k = 4x maior (~14.4 MB/hora) - excede limite Telegram

#### 2. Configure R2 para Produção

Para evitar perda de arquivos no Railway:
1. ✅ Configure credenciais R2
2. ✅ Ative cleanup automático (GitHub Actions)
3. ✅ Monitore uso de storage

#### 3. Telegram: Envio Inteligente

O bot já implementa:
- ✅ Verifica tamanho antes de enviar
- ✅ Skip arquivos > 50 MB com aviso
- ✅ Sugere download via web para arquivos grandes

#### 4. Railway: Otimização de RAM

Com livros grandes, Railway pode ficar sem RAM (512 MB free tier):

**Solução**: Processar capítulos sequencialmente (já implementado)
```python
# AudioConverter sempre processa sequencialmente
result = await self._convert_chapters_sequential(chapters, ...)
```

**Monitorar**: Railway Dashboard > Metrics > Memory Usage

Se exceder 512 MB:
- Reduzir `batch_size` (padrão: 1)
- Upgrade para Railway Pro ($5/mês = 1 GB RAM)

#### 5. Cleanup Automático

O sistema mantém arquivos por **48 horas**:
- ✅ Local: Railway cleanup endpoint
- ✅ R2: Metadata com TTL
- ✅ GitHub Actions: Cron a cada 6 horas

**Testar manualmente**:
```bash
# Local
curl -X POST "https://seu-app.railway.app/api/cleanup?max_age_hours=48"

# Verificar health
curl "https://seu-app.railway.app/api/health"
```

### Quando Ultrapassar Limites

#### Telegram > 50 MB por capítulo

**Problema**: Livros com capítulos muito longos (>14 horas)

**Soluções**:
1. **Split manual**: Dividir EPUB em partes menores
2. **Usar Web App**: Download via R2 (sem limite 50MB)
3. **Reduzir bitrate**: `6k` ao invés de `8k` (experimental)

#### Railway > 500h/mês (Free Tier)

**Problema**: Muitos usuários = horas CPU excessivas

**Soluções**:
1. **Upgrade Railway**: Pro ($20/mês = unlimited)
2. **Migrar para Render**: Free tier mais generoso
3. **Self-host**: VPS próprio

#### R2 > 10 GB

**Problema**: Storage total excede free tier

**Soluções**:
1. **Reduzir TTL**: 24h ao invés de 48h
2. **Upgrade R2**: $0.015/GB/mês (muito barato)
3. **Cleanup agressivo**: Rodar a cada 2 horas

### Checklist de Produção

Antes de abrir para usuários:

- [ ] ✅ Railway com variáveis R2 configuradas
- [ ] ✅ Cloudflare R2 bucket criado e público
- [ ] ✅ GitHub Actions cleanup configurado (secret `API_URL`)
- [ ] ✅ Frontend com `VITE_API_BASE` correto
- [ ] ✅ Testar conversão completa (livro ~300 páginas)
- [ ] ✅ Verificar arquivos no R2
- [ ] ✅ Testar download após 48h (deve falhar = cleanup OK)
- [ ] ✅ Monitorar uso de RAM no Railway

---

## 📊 Monitoramento

### Railway

- **Logs em tempo real**: Dashboard > Deployments > View Logs
- **Métricas**: Dashboard > Metrics (CPU, RAM, Network)
- **Custo**: Free tier = $5/mês (~500 horas)

### Cloudflare Pages

- **Analytics**: Dashboard > Analytics
- **Build logs**: Dashboard > Deployments > View Logs
- **Custo**: 100% grátis (unlimited requests)

---

## 💰 Custos Estimados

| Serviço | Plano Grátis | Custo após Limite |
|---------|-------------|-------------------|
| **Railway** | $5 crédito/mês | $0.01/min CPU (~$7/mês) |
| **Cloudflare Pages** | Ilimitado | Sempre grátis |
| **Telegram Bot** | Ilimitado | Sempre grátis |

**Estimativa**: Grátis para uso pessoal/baixo tráfego

---

## 🚀 Deploy Alternativo: Render.com

Se preferir **Render.com** em vez do Railway:

### Backend (Render)

1. Criar **Web Service**
2. Conectar repositório GitHub
3. Configurar:
   - **Build Command**: `pip install -r python_app/requirements.txt`
   - **Start Command**: `cd python_app && uvicorn server:app --host 0.0.0.0 --port $PORT`
4. Adicionar variáveis de ambiente (igual Railway)

**Vantagem**: Plano grátis sempre ativo (sem sleep)  
**Desvantagem**: Build mais lento (~10 min)

---

## 📝 Checklist Final

### Web App (Railway + Cloudflare)

- [ ] Backend rodando no Railway com logs sem erros
- [ ] URL do backend obtida e copiada
- [ ] Frontend buildado localmente sem erros
- [ ] Frontend deployado no Cloudflare Pages
- [ ] Variável `VITE_API_BASE` configurada no Cloudflare
- [ ] Variável `FRONTEND_URL` configurada no Railway
- [ ] Teste completo: upload EPUB → conversão → download MP3

### Bot Telegram

- [ ] Bot criado no @BotFather
- [ ] Token copiado e salvo
- [ ] Variável `TELEGRAM_BOT_TOKEN` configurada no Railway
- [ ] Bot rodando sem erros nos logs
- [ ] Teste completo: enviar EPUB → receber MP3s

---

## 🆘 Suporte

Problemas? Abra uma issue: [GitHub Issues](https://github.com/seu-usuario/Epub-to-Mp3/issues)

**Documentação:**
- Railway: https://docs.railway.app
- Cloudflare Pages: https://developers.cloudflare.com/pages
- Telegram Bot API: https://core.telegram.org/bots/api
