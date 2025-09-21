# 📚 EBook TTS Converter

Converte ebooks (EPUB/PDF) em audiolivros MP3 por capítulo usando diferentes engines TTS.

## 🚀 Características

- **Múltiplos Engines TTS**: Edge-TTS (online), Coqui TTS (local), Piper (local)
- **Suporte PT-BR**: Vozes em português brasileiro de alta qualidade
- **Cache Inteligente**: Retoma conversões e permite trocar modelos
- **Progresso Detalhado**: ETA, velocidade e estatísticas em tempo real
- **Pausas Naturais**: Entre títulos, capítulos e parágrafos
- **Organização SOLID**: Código bem estruturado e extensível

## 📋 Pré-requisitos

### Obrigatórios
```bash
# Python 3.8+
python -m pip install --upgrade pip

# FFmpeg (para conversão de áudio)
# Ubuntu/Debian:
sudo apt install ffmpeg

# macOS:
brew install ffmpeg

# Windows: baixe de https://ffmpeg.org/
```

### Engines TTS (pelo menos um)

#### 1. Edge-TTS (Recomendado - Rápido)
```bash
pip install edge-tts
```
- ✅ Rápido e gratuito
- ❌ Requer internet (Microsoft processa o texto)

#### 2. Coqui TTS (100% Local)
```bash
pip install TTS
```
- ✅ 100% privado e local
- ❌ Mais lento, requer mais RAM

#### 3. Piper (100% Local + Rápido)
```bash
# Instalar Piper CLI
# Ubuntu/Debian:
sudo apt install piper-tts

# Baixar modelos PT-BR em ./models/
wget https://github.com/rhasspy/piper/releases/download/v1.2.0/pt_BR-faber-medium.onnx
mkdir -p models && mv pt_BR-faber-medium.onnx models/
```

## 🛠️ Instalação

### Método 1: Clone do repositório
```bash
git clone <repo-url>
cd ebook-tts-converter
pip install -r requirements.txt
```

### Método 2: Instalação mínima
```bash
# Dependências base
pip install beautifulsoup4 ebooklib PyPDF2

# Escolha um engine TTS:
pip install edge-tts        # OU
pip install TTS            # OU instale Piper manualmente
```

## 📖 Uso

### Uso Básico (Menu Interativo)
```bash
python main.py meu_livro.epub
```

### Uso Avançado (Parâmetros)
```bash
# Edge-TTS com voz específica
python main.py livro.pdf --engine edge --voice pt-BR-FranciscaNeural

# Coqui TTS com modelo XTTS v2
python main.py livro.epub --engine coqui --coqui-model tts_models/multilingual/multi-dataset/xtts_v2

# Piper com modelo customizado
python main.py livro.pdf --engine piper --model-path ./models/pt_BR-faber-medium.onnx

# Reprocessar ignorando cache
python main.py livro.epub --no-cache

# Configurações de áudio
python main.py livro.epub --bitrate 64k --ar 44100
```

### Novos Comandos
- `python main.py convert ...` continua disponível (compatível com o uso anterior)
- `python main.py menu <arquivo>` inicia direto o menu interativo
- `python main.py menu -h` mostra a ajuda específica do menu

### Autocomplete com TAB
1. Certifique-se de instalar os requisitos: `pip install -r requirements.txt` (inclui `argcomplete`)
2. Torne o script executável: `chmod +x main.py`
3. Ative a conclusão no shell atual (exemplo zsh):
   ```bash
   eval "$(register-python-argcomplete ./main.py)"
   ```
   Para manter permanentemente, adicione o comando acima ao seu `~/.zshrc` ou `~/.bashrc`.

## 🎭 Vozes Disponíveis

### Edge-TTS (Português BR)
- **Femininas**: Francisca ⭐, Brenda, Elza, Giovanna, Leila, Leticia, Manuela, Yara
- **Masculinas**: Antonio, Donato, Fabio, Humberto, Julio, Nicolau, Valerio

### Coqui TTS
- **XTTS v2**: Melhor qualidade, suporte a clonagem de voz ⭐
- **XTTS v1.1**: Boa qualidade, mais rápido
- **YourTTS**: Qualidade OK, mais rápido
- **CV-VITS**: Português PT-PT

### Piper
- **pt_BR-faber-medium**: Masculino, recomendado ⭐
- **pt_BR-faber-low**: Masculino, mais rápido
- **pt_BR-edresson-low**: Masculino, alternativo

## 🔊 Clonagem de Voz (XTTS v2)

Para usar sua própria voz com XTTS v2:

1. **Grave sua voz**: 6-10 segundos, áudio limpo, português
2. **Salve como**: `./reference_voice.wav`
3. **Execute**: `python main.py livro.epub --engine coqui`
4. **Selecione**: XTTS v2 no menu

```bash
# Exemplo com ffmpeg para converter áudio
ffmpeg -i minha_voz.mp3 -ar 22050 -ac 1 reference_voice.wav
```

## 📁 Estrutura do Projeto

```
ebook-tts-converter/
├── main.py                 # Ponto de entrada
├── requirements.txt        # Dependências
├── src/
│   ├── config.py          # Configurações centralizadas
│   ├── progress_tracker.py # Rastreamento de progresso
│   ├── ebook_reader.py    # Leitores EPUB/PDF
│   ├── cache_manager.py   # Gerenciamento de cache
│   ├── tts_factory.py     # Factory para engines TTS
│   ├── converter.py       # Conversor principal
│   ├── utils.py          # Utilitários gerais
│   ├── tts/
│   │   ├── base.py       # Interfaces base
│   │   ├── edge_engine.py # Engine Edge-TTS
│   │   ├── coqui_engine.py # Engine Coqui TTS
│   │   └── piper_engine.py # Engine Piper
│   └── ui/
│
