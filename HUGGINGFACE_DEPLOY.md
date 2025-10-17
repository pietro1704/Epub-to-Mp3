# 🚀 Deploy no Hugging Face Spaces

Guia rápido para deploy do EPUB to MP3 Converter no Hugging Face Spaces.

## 📋 Pré-requisitos

- Conta no [Hugging Face](https://huggingface.co)
- Repositório GitHub sincronizado

## 🎯 Passo a Passo

### 1. Criar Space

1. Acesse [huggingface.co/spaces](https://huggingface.co/spaces)
2. Clique em **"Create new Space"**
3. Configurar:
   - **Name**: `epub-to-mp3-converter`
   - **License**: MIT
   - **SDK**: Gradio
   - **Hardware**: CPU basic (FREE)
   - **Visibility**: Public

### 2. Conectar ao GitHub

**Opção A: Push direto para o Space**

```bash
# Clone o space
git clone https://huggingface.co/spaces/SEU_USUARIO/epub-to-mp3-converter

# Copie os arquivos necessários
cp app.py epub-to-mp3-converter/
cp requirements.txt epub-to-mp3-converter/
cp packages.txt epub-to-mp3-converter/
cp README_SPACE.md epub-to-mp3-converter/README.md
cp -r python_app epub-to-mp3-converter/

# Commit e push
cd epub-to-mp3-converter
git add .
git commit -m "Initial commit: EPUB to MP3 Converter"
git push
```

**Opção B: Sync com GitHub (recomendado)**

1. No Space, vá em **Settings**
2. Em **"Repository"**, conecte seu GitHub repo
3. Configure branch: `main` ou `master`
4. Ative **"Auto sync"**

### 3. Verificar Arquivos

Certifique-se que os seguintes arquivos estão na **raiz** do Space:

```
/
├── app.py                    # ✅ Entry point Gradio
├── requirements.txt          # ✅ Python dependencies
├── packages.txt             # ✅ System packages (ffmpeg)
├── README.md                # ✅ Space card (renomeie README_SPACE.md)
└── python_app/              # ✅ Código do converter
    ├── src/
    │   ├── converter.py
    │   ├── ebook_reader.py
    │   ├── config.py
    │   └── tts/
    │       └── edge_engine.py
    └── ...
```

### 4. Build e Deploy

O Hugging Face automaticamente:
- ✅ Instala pacotes do `packages.txt` (ffmpeg)
- ✅ Instala Python deps do `requirements.txt`
- ✅ Roda `app.py` com Gradio
- ✅ Gera URL: `https://huggingface.co/spaces/SEU_USUARIO/epub-to-mp3-converter`

**Tempo de build**: ~3-5 minutos

### 5. Verificar Logs

1. Acesse o Space
2. Vá em **"Logs"** (canto superior direito)
3. Aguarde até ver:
   ```
   Running on local URL:  http://0.0.0.0:7860
   Running on public URL: https://xxx.gradio.live
   ```

## ✅ Testar o Space

1. Acesse a URL do Space
2. Envie um EPUB pequeno (< 5MB)
3. Selecione voz "Francisca"
4. Clique em "Converter"
5. Baixe os MP3s gerados

## 🐛 Troubleshooting

### Erro: "apt-get: Unable to locate package #"

**Causa**: `packages.txt` tinha comentários

**Solução**: Use o novo `packages.txt` (só contém `ffmpeg`)

### Erro: "ModuleNotFoundError: No module named 'edge_tts'"

**Causa**: `requirements.txt` não instalado

**Solução**: Verificar que `requirements.txt` está na raiz

### Erro: "FileNotFoundError: python_app/src/converter.py"

**Causa**: Pasta `python_app` não copiada

**Solução**: Copiar toda a pasta `python_app` para o Space

### Build muito lento (> 10 min)

**Causa**: Dependências pesadas (PyTorch)

**Solução**: Verificar que `requirements.txt` **NÃO** inclui:
- ❌ `torch`
- ❌ `torchaudio`
- ❌ `TTS` (Coqui)
- ✅ Só `edge-tts` (leve)

### Space fica "Building" infinitamente

**Causa**: Erro no build que não aparece nos logs

**Solução**:
1. Vá em **Settings > Factory Reboot**
2. Ou delete e recrie o Space

## 📊 Limites do Free Tier

| Recurso | Limite | Observação |
|---------|--------|------------|
| **CPU** | 2 cores | Suficiente para Edge-TTS |
| **RAM** | 16 GB | Mais que suficiente |
| **Storage** | 50 GB | Temporário (limpo após 48h) |
| **Timeout** | 60 min | Por conversão |
| **Concurrent users** | Ilimitado | Fila automática |

## 🔒 Configurações Recomendadas

### Settings > General

- **Hardware**: CPU basic (FREE)
- **Sleep time**: Never sleep (recomendado para demo público)
- **Persistent storage**: OFF (não necessário)

### Settings > Repository

- **Auto sync**: ON (se conectado ao GitHub)
- **Branch**: `main` ou `master`

### Settings > Variables

Não precisa de env vars! Tudo funciona com defaults.

## 🎨 Personalizar Space

### Trocar Emoji/Cor

Edite `README.md` (cabeçalho YAML):

```yaml
---
emoji: 🎧  # Troque aqui
colorFrom: green
colorTo: blue
---
```

### Adicionar Exemplos

No `app.py`, adicione seção `gr.Examples`:

```python
gr.Examples(
    examples=[
        ["exemplo.epub", "Francisca (Mulher) 🇧🇷"],
    ],
    inputs=[ebook_input, voice_dropdown],
)
```

## 📈 Monitorar Uso

1. Acesse o Space
2. Vá em **"Analytics"** (canto superior direito)
3. Veja:
   - Número de usuários
   - Requests por dia
   - Tempo médio de conversão

## 🔗 URLs Úteis

- **Space**: `https://huggingface.co/spaces/SEU_USUARIO/epub-to-mp3-converter`
- **Gradio**: `https://xxx.gradio.live` (gerado automaticamente)
- **Embed**: Copie código embed para usar em sites

## 🚀 Próximos Passos

- [ ] Testar com diferentes EPUB/PDF
- [ ] Adicionar mais vozes (se necessário)
- [ ] Otimizar performance
- [ ] Criar vídeo demo
- [ ] Compartilhar no Twitter/LinkedIn

## 📜 Checklist de Deploy

- [x] ✅ `app.py` criado
- [x] ✅ `requirements.txt` simplificado
- [x] ✅ `packages.txt` sem comentários
- [x] ✅ `README.md` com metadados
- [ ] Space criado no HF
- [ ] Arquivos copiados/sincronizados
- [ ] Build completo sem erros
- [ ] Teste de conversão OK
- [ ] Space público e funcionando

---

**Tempo total de setup**: ~10-15 minutos

**Dificuldade**: ⭐⭐☆☆☆ (Fácil)

Dúvidas? Abra uma issue no [GitHub](https://github.com/pietropugliesi/Epub-to-Mp3/issues)
