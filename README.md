# 📚 EBook TTS Converter

Turn EPUB/PDF ebooks into MP3 audiobooks with configurable TTS engines, cache, and narration rules.

## 🇺🇸 English

### Features
- **Multiple TTS Engines**: Edge-TTS (online), Coqui TTS, and Piper (local)
- **Brazilian Portuguese Voices**: Curated defaults with high-quality PT-BR voices
- **Smart Cache**: Resume interrupted runs and avoid re-synthesising unchanged chapters
- **Sequential by Default**: Stable, fast processing without complex parallelism
- **Optional Parallelism**: Use `--parallel` for multi-worker processing when needed
- **Detailed Progress**: Live percentage, remaining time, and per-chapter status
- **Natural Pauses**: Automatic pacing between chapters and paragraphs
- **Configurable Footnotes**: Inline narration, chapter-end summaries, or full suppression
- **Interactive Menu**: `--menu` lets you pick engine, voice, and footnote mode interactively
- **Instant Listening**: Play every chapter immediately with `--listen`
- **Persistent Audio Cache**: Chapter MP3 files copied to `.cache/<book>/audio`
- **SOLID Architecture**: Clean modules, easy to extend

### Repository Layout
- `python_app/`: original Python CLI, models, and automated tests
- `web/`: Vite-powered static frontend targeting Cloudflare Pages (`npm run build` → `web/dist`)
- Root files: shared docs (`README.md`, etc.) and configuration for the monorepo

### Prerequisites
```bash
# Python 3.8+
python -m pip install --upgrade pip

# FFmpeg (audio conversion)
# Ubuntu/Debian:
sudo apt install ffmpeg

# macOS:
brew install ffmpeg

# Windows: download from https://ffmpeg.org/
```
Install at least one TTS engine:
- `pip install edge-tts`
- `pip install TTS` (Coqui)
- Piper CLI + model download (see below)

### Installation
```bash
git clone <repo-url>
cd ebook-tts-converter
pip install -r python_app/requirements.txt
```
Minimal install:
```bash
pip install beautifulsoup4 ebooklib PyPDF2 edge-tts
```
(Add Coqui or Piper extras as required.)

### Usage Examples
> `--chapter` accepts dotted indices (e.g., `1.2`) or title fragments, while `--section` is an additional alias for more selectors. Both flags can be combined and repeated.
```bash
# Basic CLI - sequential processing (fastest, most stable)
python3 python_app/convert my_book.epub

# Enable parallel processing (auto workers)
python3 python_app/convert my_book.epub --parallel

# Parallel with specific worker count
python3 python_app/convert my_book.epub --parallel 4

# Edge-TTS with specific voice
python3 python_app/convert book.pdf --engine edge --voice pt-BR-FranciscaNeural

# Coqui XTTS v2
python3 python_app/convert book.epub --engine coqui --model tts_models/multilingual/multi-dataset/xtts_v2

# Piper with local model
python3 python_app/convert book.pdf --engine piper --model python_app/models/pt_BR-faber-medium.onnx

# Ignore cache and regenerate
python3 python_app/convert book.epub --clear-cache

# Custom audio parameters
python3 python_app/convert book.epub --bitrate 64k --ar 44100

# Skip footnotes entirely
python3 python_app/convert book.epub --no-footnote

# Read footnotes at the end of each chapter
python3 python_app/convert book.epub --footnote-chapter-end

# Listen immediately after each conversion (requires ffplay/mpv/cvlc/afplay)
python3 python_app/convert book.epub --chapter 1 --listen

# Launch interactive menu (engine, voice, footnotes)
python3 python_app/convert book.epub --menu

# Force sequential processing (even if --parallel is specified)
python3 python_app/convert book.epub --no-parallel
```

### Quick Check ("O Jardim das Aflições")
```bash
book=$(find "$HOME/Downloads" -maxdepth 1 -iname '*jardim*' -print -quit)
python python_app/convert "$book" --engine piper --model python_app/models/pt_BR-faber-medium.onnx --chapter 1
```
> Ensure the `piper` CLI is installed and available on `PATH` (`pip install piper-tts` or your OS package). Remove `--chapter 1` to process the full book once synthesis succeeds.

### Selective Conversion
- Single chapter: `python3 python_app/convert book.epub --chapter 3`
- Specific section: `python3 python_app/convert book.epub --section 2.1`
- Skip footnotes: `python3 python_app/convert book.epub --section 2.1 --no-footnote`
- Footnotes at chapter end: `python3 python_app/convert book.epub --section 2.1 --footnote-chapter-end`

### Frontend (Cloudflare Pages)
```bash
cd web
npm install
npm run dev
```
- Override the backend target during local development: `VITE_API_BASE=http://localhost:8787 npm run dev`.
- Build before deploying: `npm run build` (outputs to `web/dist`). Point your Cloudflare Pages project to the `web` directory with `npm run build` as the build command.
- Set `VITE_API_BASE` on Cloudflare Pages to the public URL that proxies requests to the Python converter (Worker, Fly.io, etc.).

### Shell Autocomplete
```bash
# Make the script executable
chmod +x python_app/convert

# Enable completion for current shell session (zsh example)
eval "$(register-python-argcomplete ./python_app/convert)"
```
Add the command above to your shell RC file (`~/.zshrc`, `~/.bashrc`, etc.) for persistence.

### Available Voices
- **Edge-TTS PT-BR**
  - Female: Francisca, Brenda, Elza, Giovanna, Leila, Leticia, Manuela, Yara
  - Male: Antonio, Donato, Fabio, Humberto, Julio, Nicolau, Valerio
- **Coqui TTS**
  - XTTS v2 (best quality, voice cloning)
  - XTTS v1.1 (faster)
  - YourTTS (fast, good quality)
  - CV-VITS (PT-PT)
- **Piper**
  - `pt_BR-faber-medium` (recommended)
  - `pt_BR-faber-low`
  - `pt_BR-edresson-low`

### Voice Cloning (Coqui XTTS v2)
1. Record 6–10 seconds of clean PT-BR audio
2. Save as `./reference_voice.wav`
3. Run `python -m python_app.main convert book.epub --engine coqui`
4. Choose XTTS v2 in the interactive menu

Convert formats if needed:
```bash
ffmpeg -i my_voice.mp3 -ar 22050 -ac 1 reference_voice.wav
```

---

## 🇧🇷 Português

Converte ebooks (EPUB/PDF) em audiolivros MP3 por capítulo usando diferentes engines TTS.

### Características
- **Múltiplos Engines TTS**: Edge-TTS (online), Coqui TTS (local), Piper (local)
- **Suporte PT-BR**: Vozes em português brasileiro de alta qualidade
- **Cache Inteligente**: Retoma conversões e permite trocar modelos
- **Sequencial por Padrão**: Processamento estável e rápido sem complexidade
- **Paralelismo Opcional**: Use `--parallel` para múltiplos workers quando necessário
- **Progresso Detalhado**: ETA, velocidade e estatísticas em tempo real
- **Pausas Naturais**: Entre títulos, capítulos e parágrafos
- **Notas Narradas**: Notas de rodapé anunciadas no fluxo da leitura
- **Notas Configuráveis**: Escolha entre leitura inline, ao fim do capítulo ou ignorar
- **Audição Imediata**: Use `--listen` para ouvir capítulos assim que forem gerados
- **Cache Persistente**: Arquivos MP3 ficam em `.cache/<livro>/audio` (limpe com `--clear-cache`)
- **Organização SOLID**: Código bem estruturado e extensível
- **Menu Interativo**: `--menu` permite escolher engine, voz e modo das notas em tempo real

### Estrutura do Repositório
- `python_app/`: CLI Python original, modelos e testes automatizados
- `web/`: frontend estático com Vite para deploy no Cloudflare Pages (build em `web/dist`)
- Arquivos na raiz: documentação compartilhada (`README.md`) e configs do monorepo

### Pré-requisitos
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

Instale pelo menos um engine TTS:
- `pip install edge-tts`
- `pip install TTS`
- Instale o Piper CLI e baixe um modelo PT-BR

### Instalação
```bash
git clone <repo-url>
cd ebook-tts-converter
pip install -r python_app/requirements.txt
```

Instalação mínima:
```bash
pip install beautifulsoup4 ebooklib PyPDF2 edge-tts
```
(Adicione Coqui ou Piper conforme necessário.)

### Uso
> `--chapter` aceita índices com ponto (por exemplo, `1.2`) ou trechos do título. `--section` é um alias extra para combinar múltiplos filtros; use quantas vezes quiser.
```bash
# CLI básica - processamento sequencial (mais rápido e estável)
python3 python_app/convert meu_livro.epub

# Habilitar processamento paralelo (workers automáticos)
python3 python_app/convert meu_livro.epub --parallel

# Paralelo com número específico de workers
python3 python_app/convert meu_livro.epub --parallel 4

# Edge-TTS com voz específica
python3 python_app/convert livro.pdf --engine edge --voice pt-BR-FranciscaNeural

# Coqui XTTS v2
python3 python_app/convert livro.epub --engine coqui --model tts_models/multilingual/multi-dataset/xtts_v2

# Piper com modelo local
python3 python_app/convert livro.pdf --engine piper --model python_app/models/pt_BR-faber-medium.onnx

# Reprocessar ignorando cache
python3 python_app/convert livro.epub --clear-cache

# Configurações de áudio
python3 python_app/convert livro.epub --bitrate 64k --ar 44100

# Ignorar notas de rodapé
python3 python_app/convert livro.epub --no-footnote

# Ler notas ao fim do capítulo
python3 python_app/convert livro.epub --footnote-chapter-end

# Ouvir o resultado direto no terminal (requer ffplay/mpv/cvlc/afplay)
python3 python_app/convert livro.epub --chapter 1 --listen

# Abrir o menu interativo (engine, voz, notas)
python3 python_app/convert livro.epub --menu

# Forçar processamento sequencial (mesmo com --parallel)
python3 python_app/convert livro.epub --no-parallel
```

### Checagem rápida ("O Jardim das Aflições")
```bash
livro=$(find "$HOME/Downloads" -maxdepth 1 -iname '*jardim*' -print -quit)
python3 python_app/convert "$livro" --engine piper --model python_app/models/pt_BR-faber-medium.onnx --chapter 1
```
> Garanta que o binário `piper` está instalado e disponível no `PATH` (`pip install piper-tts` ou pacote da distro). Remova `--chapter 1` para converter o livro inteiro após validar a síntese.

### Conversão Seletiva
- Converter apenas um capítulo: `python3 python_app/convert livro.epub --chapter 3`
- Converter uma seção específica: `python3 python_app/convert livro.epub --section 2.1`
- Ignorar notas: `python3 python_app/convert livro.epub --section 2.1 --no-footnote`
- Notas ao fim do capítulo: `python3 python_app/convert livro.epub --section 2.1 --footnote-chapter-end`

### Frontend (Cloudflare Pages)
```bash
cd web
npm install
npm run dev
```
- Durante o desenvolvimento aponte para o backend local: `VITE_API_BASE=http://localhost:8787 npm run dev`.
- Faça o build antes do deploy: `npm run build` (gera `web/dist`). Configure o projeto no Cloudflare Pages com diretório `web` e comando `npm run build`.
- Defina a variável `VITE_API_BASE` no Pages para o endpoint público que expõe a API Python (Worker, Fly.io, etc.).

### Autocomplete com TAB
```bash
chmod +x python_app/convert
eval "$(register-python-argcomplete ./python_app/convert)"
```
Adicione ao `~/.zshrc` ou `~/.bashrc` para manter permanentemente.

### Vozes Disponíveis
- **Edge-TTS (Português BR)**
  - Femininas: Francisca, Brenda, Elza, Giovanna, Leila, Leticia, Manuela, Yara
  - Masculinas: Antonio, Donato, Fabio, Humberto, Julio, Nicolau, Valerio
- **Coqui TTS**
  - XTTS v2 (melhor qualidade, suporte a clonagem)
  - XTTS v1.1 (boa qualidade, mais rápido)
  - YourTTS (rápido, qualidade boa)
  - CV-VITS (Português PT)
- **Piper**
  - `pt_BR-faber-medium` (recomendado)
  - `pt_BR-faber-low`
  - `pt_BR-edresson-low`

### Clonagem de Voz (Coqui XTTS v2)
1. Grave 6–10 segundos de áudio limpo em português
2. Salve como `./reference_voice.wav`
3. Execute `python -m python_app.main convert livro.epub --engine coqui`
4. Selecione XTTS v2 no menu interativo

Exemplo de conversão:
```bash
ffmpeg -i minha_voz.mp3 -ar 22050 -ac 1 reference_voice.wav
```

### Estrutura do Projeto
```
ebook-tts-converter/
├── README.md
├── pytest.ini
└── python_app/
    ├── __init__.py
    ├── convert
    ├── find_chapter.py
    ├── main.py
    ├── models/
    ├── output/
    ├── requirements.txt
    ├── src/
    ├── tests/
    └── verbose_output.txt
```

### Licença
Consulte o arquivo `LICENSE` (se disponível) ou as instruções do repositório.
