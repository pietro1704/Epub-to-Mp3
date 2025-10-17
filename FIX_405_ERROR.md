# 🚨 SOLUÇÃO RÁPIDA: Erro 405

## Problema
```
Erro: Backend responded with status 405
```

## Causa
Frontend no Cloudflare está tentando acessar o backend no **próprio domínio** ao invés do Railway.

## Solução em 3 Passos

### 1️⃣ Obter URL do Backend Railway

1. Acesse [railway.app](https://railway.app)
2. Abra seu projeto
3. Vá em **Settings > Networking > Generate Domain**
4. Copie a URL (ex: `https://epub-to-mp3-production.up.railway.app`)

### 2️⃣ Configurar Cloudflare Pages

1. Acesse [dash.cloudflare.com](https://dash.cloudflare.com)
2. Vá em **Workers & Pages**
3. Selecione seu projeto
4. **Settings > Environment variables**
5. Adicione:
   - **Name**: `VITE_API_BASE`
   - **Value**: `https://epub-to-mp3-production.up.railway.app` (sua URL do Railway)
   - **Environment**: `Production`
6. Clique em **Save**

### 3️⃣ Redeploy

1. Ainda no Cloudflare Pages, vá em **Deployments**
2. Clique nos **3 pontos** do último deployment
3. Selecione **Retry deployment**
4. Aguarde ~2 minutos

## ✅ Verificar se Funcionou

Abra o site e pressione **F12** (DevTools):

1. Vá na aba **Network**
2. Tente fazer upload de um arquivo
3. Procure pela requisição `convert`
4. Verifique a URL:

✅ **Correto**: `https://seu-backend.railway.app/api/convert`  
❌ **Errado**: `https://seu-app.pages.dev/api/convert`

## 🔍 Debug Adicional

### No navegador (Console F12):
```javascript
// Cole isso no console do navegador:
fetch('https://seu-backend.railway.app/api/jobs/test')
  .then(r => console.log('Status:', r.status))
  .catch(e => console.error('Erro:', e));

// Se retornar "Status: 404" = backend está funcionando!
// Se der erro de CORS = precisa configurar FRONTEND_URL no Railway
```

### Configurar CORS no Railway

Se tiver erro de CORS:

1. Railway > Seu projeto > Variables
2. Adicionar:
   ```
   FRONTEND_URL=https://seu-app.pages.dev
   ```
3. Railway faz redeploy automático (~1 min)

## 📚 Documentação Completa

Para setup completo, veja: [DEPLOY.md](./DEPLOY.md)
