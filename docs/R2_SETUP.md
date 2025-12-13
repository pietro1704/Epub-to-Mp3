# Configuração do Cloudflare R2 (Gratuito)

Este guia mostra como configurar o Cloudflare R2 para armazenamento permanente de arquivos convertidos.

## Por que usar R2?

- ✅ **Gratuito**: 10 GB de armazenamento
- ✅ **Permanente**: Arquivos não são perdidos ao reiniciar o servidor
- ✅ **Rápido**: CDN global da Cloudflare
- ✅ **Sem egress fees**: Downloads gratuitos (diferente do S3)

## Passo 1: Criar Conta Cloudflare (Gratuito)

1. Acesse [cloudflare.com](https://cloudflare.com)
2. Clique em "Sign Up" (canto superior direito)
3. Crie sua conta com email e senha
4. Verifique seu email

## Passo 2: Criar Bucket R2

1. Faça login no dashboard da Cloudflare
2. No menu lateral esquerdo, clique em **R2**
3. Clique em **"Create bucket"**
4. Configure:
   - **Bucket name**: `epub-to-mp3` (ou qualquer nome que preferir)
   - **Location**: Escolha a região mais próxima (ex: Automatic)
5. Clique em **"Create bucket"**

## Passo 3: Obter Credenciais de API

### 3.1 Account ID
1. No dashboard, clique em **R2** no menu lateral
2. Copie o **Account ID** que aparece no canto superior direito
   - Exemplo: `abc123def456...`

### 3.2 Access Key e Secret Key
1. Ainda em R2, vá em **"Manage R2 API Tokens"** (canto superior direito)
2. Clique em **"Create API Token"**
3. Configure:
   - **Token name**: `epub-to-mp3-api`
   - **Permissions**: Selecione **"Object Read & Write"**
   - **TTL**: Leave as "Forever" ou configure expiração
   - **Specify bucket(s)**: Selecione `epub-to-mp3` (ou o bucket que criou)
4. Clique em **"Create API Token"**
5. ⚠️ **IMPORTANTE**: Copie e salve:
   - **Access Key ID**: Exemplo: `abc123...`
   - **Secret Access Key**: Exemplo: `xyz789...` (não será mostrado novamente!)

## Passo 4: Configurar URL Pública (Opcional mas Recomendado)

### Opção A: R2.dev Domain (Mais Fácil)
1. No bucket `epub-to-mp3`, vá em **Settings**
2. Em **"Public access"**, clique em **"Allow Access"**
3. Ative **"R2.dev subdomain"**
4. Copie a URL pública:
   - Exemplo: `https://pub-xxxxxxxxxxxxx.r2.dev`

### Opção B: Custom Domain (Opcional)
Se você tem um domínio próprio, pode configurar um custom domain.

## Passo 5: Configurar no Hugging Face Space

1. Vá para seu Space: `https://huggingface.co/spaces/pi1704/epub-to-mp3`
2. Clique em **"Settings"** (aba superior)
3. Role até **"Repository secrets"**
4. Adicione as seguintes variáveis:

### Variáveis Obrigatórias:

| Nome | Valor | Exemplo |
|------|-------|---------|
| `R2_ACCOUNT_ID` | Account ID copiado | `abc123def456...` |
| `R2_ACCESS_KEY_ID` | Access Key ID | `abc123...` |
| `R2_SECRET_ACCESS_KEY` | Secret Access Key | `xyz789...` |
| `R2_BUCKET_NAME` | Nome do bucket | `epub-to-mp3` |
| `R2_PUBLIC_URL` | URL pública do R2 | `https://pub-xxxxx.r2.dev` |

### Como Adicionar Cada Secret:
1. Clique em **"Add a new secret"**
2. **Name**: Cole o nome da variável (ex: `R2_ACCOUNT_ID`)
3. **Secret**: Cole o valor
4. Clique em **"Add secret"**
5. Repita para todas as 5 variáveis

## Passo 6: Reiniciar o Space

1. Volte para a aba **"Files"**
2. Clique em **"⋮"** (três pontos) no canto superior direito
3. Clique em **"Factory reboot"**
4. Aguarde ~30 segundos

## Passo 7: Verificar se Está Funcionando

Após o reboot, faça uma conversão de teste:

1. Envie um EPUB pequeno
2. Aguarde a conversão completar
3. Nos logs, você deve ver:
   ```
   ☁️ Enviando arquivos para storage permanente...
     ✅ 001 - Capítulo 1.mp3 → R2
     ✅ Livro.zip → R2
   ```

Se aparecer **"⚠️ fallback local"**, verifique as credenciais.

## Verificação de Custos (Tier Gratuito)

O plano gratuito do R2 inclui:
- **Armazenamento**: 10 GB/mês (grátis)
- **Operações Classe A** (uploads): 1 milhão/mês (grátis)
- **Operações Classe B** (downloads): 10 milhões/mês (grátis)
- **Egress (downloads)**: ILIMITADO (grátis) ⭐

**Estimativa de uso:**
- Livro médio: ~50-100 MB
- Você pode armazenar ~100-200 livros no tier gratuito
- Downloads são sempre gratuitos!

## Limpeza Automática

O sistema já está configurado para limpar arquivos antigos:
- Arquivos são marcados com TTL de 48 horas
- Endpoint `/api/cleanup` remove arquivos >48h
- Configure um cron job no HF para chamar isso periodicamente

## Troubleshooting

### "R2 not configured"
- Verifique se TODAS as 5 variáveis estão configuradas nos Secrets
- Verifique se não há espaços extras nos valores
- Reinicie o Space

### "Failed to upload to R2"
- Verifique se o Access Key tem permissões de "Object Read & Write"
- Verifique se o bucket existe
- Verifique se o Account ID está correto

### "403 Forbidden"
- Verifique se o token não expirou
- Verifique se o token tem permissões para o bucket específico
- Recrie o token se necessário

## Segurança

⚠️ **NUNCA** commite credenciais no código!
- Sempre use Secrets do Hugging Face
- Nunca compartilhe seu Secret Access Key
- Se expôs acidentalmente, revogue o token imediatamente e crie um novo

## URLs Úteis

- [Cloudflare Dashboard](https://dash.cloudflare.com/)
- [R2 Documentation](https://developers.cloudflare.com/r2/)
- [R2 Pricing](https://www.cloudflare.com/plans/developer-platform/)
