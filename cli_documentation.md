# 📚 Documentação CLI - EbookToAudio

Conversor de EPUB/PDF para MP3 usando TTS (Text-to-Speech). Suporte completo para português brasileiro com múltiplos engines TTS.

## 🚀 Uso Básico

```bash
python main.py arquivo.epub
python main.py arquivo.pdf
```

## 📖 Índice

- [Instalação](#instalação)
- [Uso Interativo](#uso-interativo)
- [Uso Automatizado](#uso-automatizado)
- [Engines TTS](#engines-tts)
- [Gerenciamento de Cache](#gerenciamento-de-cache)
- [Configurações de Áudio](#configurações-de-áudio)
- [Exemplos Práticos](#exemplos-práticos)
- [Troubleshooting](#troubleshooting)

---

## 🔧 Instalação

### Dependências Core
```bash
pip install -r requirements.txt
```

### Dependências por Engine

**Edge-TTS (Recomendado - mais rápido)**
```bash
pip install edge-tts
```

**Coqui TTS (100% local)**
```bash
pip install TTS torch torchaudio
```

**Piper TTS (CLI local)**
```bash
# Instalar Piper CLI separadamente
# Download modelos: https://github.com/rhasspy/piper/releases
```

**FFmpeg (obrigatório)**
```bash
# Ubuntu/Debian
sudo apt install ffmpeg

# macOS
brew install ffmpeg

# Windows
# Download: https://ffmpeg.org/download.html
```

---

## 🎯 Uso Interativo

### Modo Menu Completo
```bash
python main.py livro.epub
```
- Detecta engines disponíveis
- Menu de seleção de TTS
- Menu de seleção de voz
- Preview das vozes
- Configuração automática

### Menu apenas para Voz (engine pré-definido)
```bash
python main.py livro.epub --engine edge
python main.py livro.epub --engine coqui
python main.py livro.epub --engine piper
```

---

## 🤖 Uso Automatizado

### Edge-TTS (Microsoft)

**Voz padrão brasileira**
```bash
python main.py livro.epub --engine edge
```

**Voz específica**
```bash
python main.py livro.epub --engine edge --voice pt-BR-FranciscaNeural
```

**Todas as vozes Edge disponíveis:**
- `pt-BR-FranciscaNeural` - Feminina, natural ⭐
- `pt-BR-BrendaNeural` - Feminina, jovem
- `pt-BR-ElzaNeural` - Feminina, madura
- `pt-BR-GiovannaNeural` - Feminina, suave
- `pt-BR-LeilaNeural` - Feminina, clara
- `pt-BR-LeticiaNeural` - Feminina, jovem
- `pt-BR-ManuelaNeural` - Feminina, expressiva
- `pt-BR-YaraNeural` - Feminina, doce
- `pt-BR-AntonioNeural` - Masculino, padrão
- `pt-BR-DonatoNeural` - Masculino, grave
- `pt-BR-FabioNeural` - Masculino, jovem
- `pt-BR-HumbertoNeural` - Masculino, firme
- `pt-BR-JulioNeural` - Masculino, forte
- `pt-BR-NicolauNeural` - Masculino, claro
- `pt-BR-ValerioNeural` - Masculino, profundo

### Coqui TTS (Local)

**Modelo XTTS v2 (padrão)**
```bash
python main.py livro.epub --engine coqui
```

**Modelo específico**
```bash
python main.py livro.epub --engine coqui --coqui-model tts_models/multilingual/multi-dataset/xtts_v2
```

**Modelos disponíveis:**
- `tts_models/multilingual/multi-dataset/xtts_v2` - Melhor qualidade ⭐
- `tts_models/multilingual/multi-dataset/xtts_v1.1` - Boa qualidade
- `tts_models/multilingual/multi-dataset/your_tts` - Mais rápido
- `tts_models/pt/cv/vits` - Português PT-PT

### Piper TTS (CLI Local)

**Modelo padrão**
```bash
python main.py livro.epub --engine piper
```

**Modelo específico**
```bash
python main.py livro.epub --engine piper --model-path ./models/pt_BR-faber-medium.onnx
```

---

## 🎛️ Engines TTS

### 🌐 Edge-TTS
- **Tipo**: Online (Microsoft)
- **Velocidade**: ⚡ Muito rápido
- **Qualidade**: 🎯 Excelente
- **Privacidade**: ⚠️ Dados enviados para Microsoft
- **Setup**: Fácil (`pip install edge-tts`)

```bash
# Exemplo completo
python main.py livro.epub \
  --engine edge \
  --voice pt-BR-FranciscaNeural \
  --bitrate 64k \
  --ar 44100
```

### 🔒 Coqui TTS
- **Tipo**: 100% Local
- **Velocidade**: 🐌 Lento (primeira vez), 🚀 rápido depois
- **Qualidade**: 🎯 Excelente (XTTS v2)
- **Privacidade**: ✅ 100% privado
- **Setup**: Médio (requer PyTorch)

```bash
# XTTS v2 com voz clonada
python main.py livro.epub \
  --engine coqui \
  --coqui-model tts_models/multilingual/multi-dataset/xtts_v2

# Coloque reference_voice.wav (6-10s) no diretório raiz
```

### 🔧 Piper TTS
- **Tipo**: CLI Local
- **Velocidade**: ⚡ Rápido
- **Qualidade**: 🎯 Boa
- **Privacidade**: ✅ 100% privado
- **Setup**: Complexo (CLI + modelos)

```bash
# Download modelo primeiro
wget https://github.com/rhasspy/piper/releases/download/v1.2.0/pt_BR-faber-medium.tar.gz
tar -xzf pt_BR-faber-medium.tar.gz -C ./models/

python main.py livro.epub \
  --engine piper \
  --model-path ./models/pt_BR-faber-medium.onnx
```

---

## 💾 Gerenciamento de Cache

### Cache Automático
```bash
# Primeira execução - cria cache
python main.py livro.epub --engine edge

# Segunda execução - usa cache (muito mais rápido)
python main.py livro.epub --engine coqui
```

### Forçar Reprocessamento
```bash
# Ignora cache existente e reprocessa arquivo
python main.py livro.epub --engine edge --no-cache
```

### Localização do Cache
- **Diretório**: `.cache/Nome_do_Livro/`
- **Estrutura**:
  ```
  .cache/
  └── Meu_Livro/
      ├── metadata.json
      ├── 01 - Capítulo 1.txt
      ├── 02 - Capítulo 2.txt
      └── ...
  ```

### Limpeza Manual
```bash
# Remove cache específico
rm -rf .cache/Nome_do_Livro/

# Remove todo cache
rm -rf .cache/
```

---

## 🎵 Configurações de Áudio

### Bitrate (qualidade vs tamanho)
```bash
# Baixa qualidade (menor arquivo)
python main.py livro.epub --bitrate 16k

# Qualidade média (padrão)
python main.py livro.epub --bitrate 32k

# Alta qualidade (arquivo maior)
python main.py livro.epub --bitrate 128k
```

### Sample Rate
```bash
# Qualidade telefone
python main.py livro.epub --ar 8000

# Qualidade padrão
python main.py livro.epub --ar 22050

# Qualidade CD
python main.py livro.epub --ar 44100
```

### Canais de Áudio
```bash
# Mono (padrão, menor arquivo)
python main.py livro.epub --ac 1

# Estéreo (maior arquivo)
python main.py livro.epub --ac 2
```

---

## 💡 Exemplos Práticos

### 🎯 Uso Típico (Recomendado)
```bash
# Edge-TTS com voz feminina natural
python main.py meu_livro.epub \
  --engine edge \
  --voice pt-BR-FranciscaNeural \
  --bitrate 32k
```

### 🔒 Máxima Privacidade
```bash
# Coqui TTS - dados nunca saem do PC
python main.py livro_privado.pdf \
  --engine coqui \
  --coqui-model tts_models/multilingual/multi-dataset/xtts_v2
```

### ⚡ Máxima Velocidade
```bash
# Edge-TTS com cache habilitado
python main.py livro_grande.epub \
  --engine edge \
  --bitrate 16k \
  --ar 16000
```

### 🎭 Voz Clonada (Coqui XTTS)
```bash
# 1. Grave sua voz (6-10 segundos, formato WAV)
# 2. Salve como reference_voice.wav no diretório raiz
# 3. Execute:
python main.py livro.epub \
  --engine coqui \
  --coqui-model tts_models/multilingual/multi-dataset/xtts_v2
```

### 📱 Para Dispositivos Móveis
```bash
# Arquivo menor, compatível com celulares
python main.py livro.epub \
  --engine edge \
  --bitrate 24k \
  --ar 22050 \
  --ac 1
```

### 🎧 Qualidade Audiófilo
```bash
# Máxima qualidade de áudio
python main.py livro.epub \
  --engine coqui \
  --bitrate 320k \
  --ar 48000 \
  --ac 2
```

### 📚 Processamento em Lote
```bash
#!/bin/bash
# Script para processar múltiplos arquivos

for file in *.epub *.pdf; do
  if [ -f "$file" ]; then
    echo "Processando: $file"
    python main.py "$file" \
      --engine edge \
      --voice pt-BR-FranciscaNeural \
      --no-cache
  fi
done
```

### 🔄 Comparação de Vozes
```bash
# Mesmo livro com vozes diferentes
python main.py livro.epub --engine edge --voice pt-BR-FranciscaNeural
python main.py livro.epub --engine edge --voice pt-BR-DonatoNeural
python main.py livro.epub --engine coqui

# Arquivos ficarão em pastas separadas
```

---

## 🐛 Troubleshooting

### Erros Comuns

**❌ "Arquivo não encontrado"**
```bash
# Verifique o caminho do arquivo
ls -la meu_livro.epub
python main.py ./caminho/completo/meu_livro.epub
```

**❌ "Engine não disponível"**
```bash
# Instale o engine necessário
pip install edge-tts  # Para Edge-TTS
pip install TTS       # Para Coqui TTS

# Verifique instalação
python -c "import edge_tts; print('Edge-TTS OK')"
python -c "import TTS; print('Coqui TTS OK')"
```

**❌ "ffmpeg não encontrado"**
```bash
# Ubuntu/Debian
sudo apt update && sudo apt install ffmpeg

# macOS
brew install ffmpeg

# Verifique instalação
ffmpeg -version
```

**❌ "PyTorch não encontrado" (Coqui)**
```bash
# Instale PyTorch
pip install torch torchaudio --index-url https://download.pytorch.org/whl/cpu

# Para GPU (opcional, mais rápido)
pip install torch torchaudio --index-url https://download.pytorch.org/whl/cu118
```

**❌ "Modelo Piper não encontrado"**
```bash
# Crie diretório e baixe modelo
mkdir -p models
cd models
wget https://github.com/rhasspy/piper/releases/download/v1.2.0/pt_BR-faber-medium.tar.gz
tar -xzf pt_BR-faber-medium.tar.gz
cd ..

# Execute especificando modelo
python main.py livro.epub --engine piper --model-path ./models/pt_BR-faber-medium.onnx
```

### Validação de Dependências
```bash
# Pula validação se houver problemas
python main.py livro.epub --skip-validation
```

### Debug Mode
```bash
# Para ver erros detalhados
python -u main.py livro.epub --engine coqui 2>&1 | tee debug.log
```

### Performance Issues

**🐌 Coqui TTS muito lento**
```bash
# Use modelo mais rápido
python main.py livro.epub \
  --engine coqui \
  --coqui-model tts_models/multilingual/multi-dataset/your_tts

# Ou use Edge-TTS para velocidade
python main.py livro.epub --engine edge
```

**💾 Pouco espaço em disco**
```bash
# Use bitrate baixo
python main.py livro.epub --bitrate 16k --ar 16000

# Limpe cache antigo
rm -rf .cache/
```

**⚠️ Problemas de encoding**
```bash
# Force UTF-8
export PYTHONIOENCODING=utf-8
python main.py livro.epub
```

---

## 📊 Comparação de Engines

| Feature | Edge-TTS | Coqui TTS | Piper TTS |
|---------|----------|-----------|-----------|
| **Velocidade** | ⚡⚡⚡ | 🐌 (1ª vez), ⚡⚡ depois | ⚡⚡ |
| **Qualidade** | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ |
| **Privacidade** | ❌ Online | ✅ 100% Local | ✅ 100% Local |
| **Setup** | ✅ Fácil | ⚠️ Médio | ❌ Complexo |
| **Voz Clonada** | ❌ | ✅ | ❌ |
| **Múltiplas Vozes** | ✅ 15 vozes | ✅ Ilimitado | ⚠️ Por modelo |
| **Tamanho Download** | ~5MB | ~2GB | ~100MB/modelo |

### Recomendações de Uso

**🚀 Para iniciantes**: Edge-TTS
```bash
python main.py livro.epub --engine edge
```

**🔒 Para privacidade**: Coqui TTS
```bash
python main.py livro.epub --engine coqui
```

**⚡ Para velocidade + local**: Piper TTS
```bash
python main.py livro.epub --engine piper
```

---

## 📁 Estrutura de Saída

```
📂 Nome_do_Livro/
├── 01 - Capítulo 1.mp3
├── 02 - Capítulo 2.mp3
├── 03 - Capítulo 3.mp3
└── ...

📂 .cache/
└── 📂 Nome_do_Livro/
    ├── metadata.json
    ├── 01 - Capítulo 1.txt
    └── ...
```

---

## 🆘 Suporte

**Problemas comuns**: Veja seção [Troubleshooting](#troubleshooting)

**Bugs**: Verifique logs e execute com `--skip-validation`

**Performance**: Use Edge-TTS para velocidade ou configure bitrate baixo

**Qualidade**: Use Coqui XTTS v2 para melhor resultado

---

*Documentação atualizada - v2.0*