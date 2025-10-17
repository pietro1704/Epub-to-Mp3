# 📊 Análise: Storage e Limites para Arquivos Grandes

## 🎯 Problema

**Livros típicos**: 100-400 MB de áudio final  
**Telegram**: Limite 50 MB/arquivo  
**Railway**: Storage efêmero (deletado após restart)  

## 📐 Cálculos de Tamanho

### Configurações Atuais (config.py)
```python
bitrate: "8k"           # 8 kbps (1 KB/s)
sample_rate: 16_000     # 16 kHz
channels: 1             # Mono
```

### Tamanho por Duração
| Duração | Tamanho (8k bitrate) | Tamanho (16k bitrate) | Tamanho (32k bitrate) |
|---------|---------------------|----------------------|----------------------|
| 1 hora  | ~3.6 MB            | ~7.2 MB             | ~14.4 MB            |
| 5 horas | ~18 MB             | ~36 MB              | ~72 MB              |
| 10 horas| ~36 MB             | ~72 MB              | ~144 MB             |
| 20 horas| ~72 MB             | ~144 MB             | ~288 MB             |
| 30 horas| ~108 MB            | ~216 MB             | ~432 MB             |

### Livro Médio (Exemplo)
- **Páginas**: 300
- **Palavras**: ~90,000
- **Duração narrada**: ~10 horas
- **Tamanho final (8k)**: ~36 MB ✅
- **Tamanho final (16k)**: ~72 MB ❌ (excede 50MB)
- **Tamanho final (32k)**: ~144 MB ❌

**Conclusão**: Bitrate 8k é ESSENCIAL para Telegram!

## 🚧 Limitações por Plataforma

### 1. Telegram Bot

| Limite | Valor | Impacto |
|--------|-------|---------|
| Tamanho arquivo | 50 MB | **CRÍTICO** - precisa split |
| Uploads simultâneos | 20/min | Médio |
| Storage bot | ∞ | Telegram guarda os arquivos |

**Estratégias**:
1. ✅ Enviar capítulos individuais (< 50 MB cada)
2. ✅ Criar ZIP apenas se todos cabem
3. ✅ Avisar usuário se livro > 50 MB
4. ❌ NÃO enviar ZIP gigante (> 50 MB)

### 2. Railway (Backend)

| Limite | Valor | Impacto |
|--------|-------|---------|
| RAM | 512 MB (free) | Alto |
| Storage | Efêmero | **CRÍTICO** - arquivos deletados |
| CPU | Shared | Médio |
| Network | 100 GB/mês | Baixo |
| Execução | ~500h/mês ($5) | Médio |

**Problemas**:
- Arquivos em `/output` são **deletados** após restart
- Restart pode acontecer a qualquer momento
- Usuário perde download se Railway reiniciar

**Estratégias**:
1. ❌ Storage local NÃO funciona para produção
2. ✅ Cloudflare R2 (S3-compatível, grátis 10GB)
3. ✅ Upload para R2 após conversão
4. ✅ Gerar URLs temporárias (24h)
5. ✅ Cleanup automático de arquivos antigos

### 3. Cloudflare Pages (Frontend)

| Limite | Valor | Impacto |
|--------|-------|---------|
| Build size | 25 MB | Baixo (frontend pequeno) |
| Storage | Nenhum | Frontend é estático |
| Requests | ∞ grátis | Nenhum |

**Sem problema**: Frontend só faz requests ao backend.

### 4. Cloudflare R2 (Storage)

| Limite | Valor | Custo |
|--------|-------|-------|
| Storage | 10 GB | **Grátis** |
| Class A ops | 1M/mês | Grátis |
| Class B ops | 10M/mês | Grátis |
| Egress | ∞ | **Grátis** |

**Melhor opção**: Compatível S3, sem custo de saída de dados!

## ✅ Solução Recomendada

### Arquitetura Final

```
┌─────────────────────┐
│  1. Usuário envia   │
│     EPUB/PDF        │
└──────────┬──────────┘
           │
           ↓
┌─────────────────────────────────────────────┐
│  2. Railway (Backend)                       │
│     ├─ Converte para MP3 (8k bitrate)      │
│     ├─ Salva temporariamente em /output    │
│     └─ Upload para Cloudflare R2           │
└──────────┬──────────────────────────────────┘
           │
           ↓
┌─────────────────────────────────────────────┐
│  3. Cloudflare R2 (Storage)                 │
│     ├─ Armazena MP3s (TTL 24-48h)          │
│     └─ Gera URLs públicas temporárias       │
└──────────┬──────────────────────────────────┘
           │
           ↓
┌─────────────────────────────────────────────┐
│  4. Usuário baixa                           │
│     ├─ Web: Download direto do R2          │
│     └─ Telegram: Bot envia do R2           │
└─────────────────────────────────────────────┘
```

### Implementação

#### Bot Telegram
```python
# Se capítulo > 50 MB: avisar e não enviar
if file_size > 50_000_000:
    await message.reply("⚠️ Capítulo muito grande (>50MB)")
    await message.reply("📥 Baixe pelo link: [URL do R2]")
else:
    # Enviar arquivo direto
    await message.reply_audio(file)
```

#### Web App
```python
# Upload para R2 após conversão
for mp3_file in output_files:
    r2_url = upload_to_r2(mp3_file, ttl=86400)  # 24h
    results.append({"url": r2_url, "name": mp3_file.name})

# Limpar arquivo local
mp3_file.unlink()
```

## 📋 Checklist de Implementação

### Fase 1: Otimização Básica
- [x] Configurar bitrate 8k (já implementado)
- [ ] Adicionar validação de tamanho antes de enviar no Telegram
- [ ] Implementar envio de capítulos individuais no bot
- [ ] Avisar usuário quando arquivo excede 50MB

### Fase 2: Storage Persistente (R2)
- [ ] Criar bucket no Cloudflare R2
- [ ] Instalar `boto3` para S3-compatible API
- [ ] Implementar upload para R2 no `server.py`
- [ ] Gerar presigned URLs (24h TTL)
- [ ] Atualizar frontend para baixar do R2

### Fase 3: Cleanup e Otimização
- [ ] Implementar cleanup automático (arquivos > 48h)
- [ ] Adicionar compressão adicional para livros grandes
- [ ] Monitorar uso de RAM no Railway
- [ ] Documentar limites no DEPLOY.md

## 🎛️ Opções de Compressão

### Para Reduzir Ainda Mais (se necessário)

```python
# Configuração ULTRA compressão (qualidade aceitável para voz)
ConversionConfig(
    bitrate="6k",          # 6 kbps (experimental)
    sample_rate=12_000,    # 12 kHz
    channels=1,
    # Opus codec (melhor que MP3 para voz)
    audio_format="opus",   # Requer ffmpeg
)
```

**Resultado**: ~27 MB para 10 horas (vs 36 MB com 8k)

### Trade-offs

| Config | Tamanho 10h | Qualidade | Compatibilidade |
|--------|-------------|-----------|-----------------|
| 32k MP3 | 144 MB | Excelente | ✅ Universal |
| 16k MP3 | 72 MB | Muito boa | ✅ Universal |
| **8k MP3** | **36 MB** | **Boa** | ✅ **Universal** |
| 6k MP3 | 27 MB | Aceitável | ✅ Universal |
| 16k Opus | 72 MB | Excelente | ⚠️ Precisa player moderno |
| 8k Opus | 36 MB | Muito boa | ⚠️ Precisa player moderno |

**Recomendação**: **8k MP3** (atual) é o melhor equilíbrio!

## 💰 Estimativa de Custos

### Cenário: 100 usuários/mês, 1 livro/usuário

| Recurso | Uso | Custo |
|---------|-----|-------|
| **Railway** | ~50h processamento | $0 (dentro do free tier) |
| **Cloudflare R2** | 10 GB storage + 100 GB egress | **$0** (dentro do free tier) |
| **Cloudflare Pages** | Unlimited requests | $0 |
| **Telegram Bot** | Unlimited | $0 |

**Total**: **$0/mês** 🎉

### Quando sai do free tier?

- **Railway**: Após ~500 horas CPU/mês (≈ 100-200 conversões)
- **R2**: Após 10 GB storage (≈ 300 livros de 36 MB cada)

**Solução**: Cleanup automático em 48h mantém < 10 GB

## 🚀 Próximos Passos

1. Implementar validação de tamanho no bot Telegram
2. Configurar Cloudflare R2
3. Integrar upload para R2 no backend
4. Adicionar cleanup automático
5. Testar com livro grande (>400 MB de texto)

---

**Autor**: Claude Code  
**Data**: 2025-10-17  
**Status**: ✅ Análise completa
