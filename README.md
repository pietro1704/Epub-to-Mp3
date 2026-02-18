---
title: EPUB to MP3 Converter
emoji: 📚
colorFrom: blue
colorTo: purple
sdk: docker
pinned: false
license: mit
---

# EPUB to MP3 Converter

Convert EPUB/PDF ebooks into MP3 audiobooks using TTS engines.

**Live Demo**: [Hugging Face Space](https://huggingface.co/spaces/pi1704/epub-to-mp3)

## Features

- **TTS Engines**: Auto (Edge/Coqui/Piper), Edge-TTS (online), Coqui TTS, Piper (local)
- **Portuguese BR Voices**: High-quality curated voices
- **Smart Cache**: Resume interrupted conversions
- **Chapter Structure**: Preserves book navigation hierarchy
- **Progress Tracking**: Real-time ETA plus per-chapter status timeline
- **Batch Conversion**: Queue multiple EPUB/PDF files or entire folders for unattended runs
- **Footnote Handling**: Inline, chapter-end, or suppressed
- **Voice Catalog API**: Frontend pulls curated voices directly from `/api/voices`
- **Telemetry Benchmarks**: `/api/telemetry` exposes real Edge/Coqui/Piper throughput data
- **Interactive Menu**: Pick engine/voice/settings interactively

## Installation

```bash
# Clone repository
git clone https://github.com/pietro1704/Epub-to-Mp3.git
cd Epub-to-Mp3

# Install dependencies
pip install -r requirements.txt

# System dependency: FFmpeg
# Ubuntu/Debian: sudo apt install ffmpeg
# macOS: brew install ffmpeg
```

## CLI Usage

### Shell Autocomplete (Optional)

Enable `.epub` and `.pdf` file autocomplete in your shell:

**For Zsh (macOS default):**
```bash
# Add to ~/.zshrc
echo "source $(pwd)/shell-completion.zsh" >> ~/.zshrc
source ~/.zshrc
```

**For Bash:**
```bash
# Install bash-completion if not already installed
# macOS: brew install bash-completion
# Ubuntu: sudo apt install bash-completion

# Add to ~/.bashrc
eval "$(register-python-argcomplete python_app/convert)"
source ~/.bashrc
```

After setup, you can use Tab to autocomplete:
```bash
./python_app/convert ~/Downloads/Book[TAB]  # Completes .epub/.pdf files
./python_app/convert book.epub --engine [TAB]  # Completes: auto, edge, coqui, piper
```

### Basic Commands

```bash
# Basic conversion (auto picks the fastest engine per chapter)
python -m python_app.main book.epub

# Force specific engine/voice
python -m python_app.main book.epub --engine edge --voice pt-BR-FranciscaNeural

# Prioritize specific chapters (these play first, rest follow)
python -m python_app.main book.epub --priority "Prólogo" --priority 5

# Interactive menu
python -m python_app.main book.epub --menu

# Single chapter
python -m python_app.main book.epub --chapter 3

# Multiple specific chapters at once (comma-separated or repeated flag)
python -m python_app.main book.epub --chapter 5.1,5.2,5.3

# Habilitar validação profunda ao final (mais lento)
python -m python_app.main book.epub --deep-validate

# Retry failed chapters automatically (default 2 rounds) or disable/force extra
python -m python_app.main book.epub --retry-failed 3            # up to 3 auto rounds
python -m python_app.main book.epub --retry-failed 0            # disable auto retries
python -m python_app.main book.epub --retry-failed-manual       # force one extra pass on failures

# Skip footnotes
python -m python_app.main book.epub --no-footnote

# Show structure only
python -m python_app.main book.epub --show-structure

# Clear cache and reprocess
python -m python_app.main book.epub --clear-cache

# Runtime optimization toggles
python -m python_app.main book.epub --prefetch --ab-auto --adaptive-checkpoint
python -m python_app.main book.epub --no-prefetch --no-ab-auto --no-adaptive-checkpoint
python -m python_app.main book.epub --stage-pipeline --stage-pipeline-depth 3
```

### Feature A/B Benchmark

```bash
python scripts/benchmark_feature_ab.py --book book.epub --engine auto --workers 2
```

The report is saved in `.cache/telemetry/feature-ab-benchmark-<host>.json`.

### Batch Conversion

Convert several books sequentially without babysitting the CLI:

```bash
# Same settings for every file (main positional + extras)
python python_app/convert book1.epub book2.pdf book3.epub

# Prefer the module entrypoint? Add the convert subcommand explicitly
python -m python_app.main convert book1.epub book2.pdf

# Process an entire folder (recursively picks .epub/.pdf)
python -m python_app.main convert --batch ~/Audiobooks/to_convert/

# Use a newline-separated manifest file and stop after the first error
python -m python_app.main convert --batch-file books.txt --stop-on-error
```

The helper script `python_app/convert` also supports batch-only runs:

```bash
python python_app/convert --batch ~/Downloads/*.epub --batch-file favorites.txt
```

For multi-process throughput, use the external worker pool:

```bash
python scripts/external_worker_pool.py ~/Books --workers 4 \
  --forward-args "--engine auto --max-performance --stage-pipeline"
```

Useful options:
- `--retries N` and `--retry-delay-seconds S` for transient failures
- `--job-timeout-seconds S` to abort a stuck book and move to next worker slot
- `--json-report path.json` to persist per-book execution stats

Arguments such as `--engine`, `--voice`, and formatting options apply to every book in the queue. `--batch` and `--batch-file` remain handy for folders, glob patterns, or long manifests. By default the converter continues after failures; add `--stop-on-error` to abort the batch on the first unsuccessful conversion.

On the Hugging Face Space, **Step 1** (“Preparar conversão”) now accepts multiple EPUB/PDF uploads at once. Drop every book into the queue, drag or use the arrows to reorder, then click “Converter” and the backend will process them sequentially using the same settings. While Step 2 is running you can drop extra files in the “Adicionar livros” card and they’ll join the queue automatically.

### Tuning Edge-TTS performance

Edge voices depend on Microsoft’s cloud, so long chapters can slow down when network latency spikes. The CLI already adapts automatically, but you can fine-tune it with env vars:

```bash
# Use smaller chunks/timeouts (values below are the defaults shipped in code)
export EDGE_CHUNK_CHARS=11000
export EDGE_MAX_SEGMENT_SECONDS=65

# Auto-fallback to offline engines for very long chapters
export EDGE_AUTO_OFFLINE_CHARS=9000
export EDGE_AUTO_OFFLINE_SECONDS=300

# Limit concurrent Edge requests (prevents queueing on HF Spaces)
export EDGE_MAX_CONCURRENCY=2
```

Lowering chunks/seconds makes each Edge request finish faster; the fallback thresholds push huge chapters directly into Coqui/Piper so the queue never stalls.

### Performance profiles (CLI vs local vs Hugging Face)

Perf flags are now automatic: the app infers a profile (HF vs local vs CLI) from the runtime (SPACE_ID + hardware) and sets Edge/Coqui/Piper concurrency and chunk sizes for you. You can still override with env vars if needed.

Set `PERF_PROFILE` to quickly dial concurrency without risking deadlocks/starvation (optional override):

- `PERF_PROFILE=hf` (default on Hugging Face Spaces): caps Edge concurrency to 3, chapter parallelism to 2/3, and worker count to available vCPUs. This matches HF docs (shared CPU, often 2 vCPU) to avoid throttling or 403s.
- `PERF_PROFILE=local` (default outside Spaces): balanced defaults from hardware auto-detect.
- `PERF_PROFILE=cli`: higher local throughput; raises default Edge and worker caps (still bounded) for multi-core boxes.

You can still override individual knobs if needed:
```bash
# Hugging Face: stay under the rate/CPU limits
export PERF_PROFILE=hf
export EDGE_MAX_CONCURRENCY=2         # optional hard cap (default from profile)
export EDGE_CHUNK_CHARS=9000          # smaller chunks avoid 60s timeouts
export EDGE_MAX_SEGMENT_SECONDS=60
export CHAPTER_PARALLEL_COUNT=1       # keep sequential to avoid CPU spikes
export COQUI_MAX_WORKERS=2            # reduce torch threading on shared CPUs
export PIPER_MAX_PROCS=1

# Local dev workstation
export PERF_PROFILE=local       # (default)

# CLI on a beefy host
export PERF_PROFILE=cli
export EDGE_MAX_CONCURRENCY=4         # raise to 6-8 only if network/CPU allow
export CHAPTER_PARALLEL_COUNT=2
export CHAPTER_PARALLEL_MAX=4
export COQUI_MAX_WORKERS=6            # keep below logical cores to avoid thrash
export PIPER_MAX_PROCS=3
```

### Teste turbo de 1 capítulo (Edge vs Piper)

O script `scripts/chapter_speedtest.py` executa a conversão real de **um capítulo** usando três cenários: Edge multilíngue, Edge pt-BR monolíngue (voz ajustada automaticamente) e Piper local. Ele usa, por padrão, o `web/public/sample.epub` (livro de teste incluso no repo) e procura automaticamente um capítulo curto para acelerar a medição. Basta apontar `--book` para qualquer EPUB/PDF para repetir o teste com seu arquivo.

```bash
# sample interno
python scripts/chapter_speedtest.py

# outro livro + cap. específico
python scripts/chapter_speedtest.py --book "~/Downloads/SeuLivro.epub" --chapter 7
```

Notas rápidas:
- Edge multilíngue respeita o limite público de ~10 req/s das vozes `MultilingualNeural`; a variante monolíngue usa ~16 req/s para fugir do rate limit mais agressivo.
- Piper usa automaticamente o modelo pt-BR recomendado em `models/` e ajusta `PIPER_MAX_PROCS` de acordo com os núcleos físicos detectados.
- Use `--keep-cache` se quiser medições super rápidas (sem limpar cache), ou deixe o padrão para forçar reconversões completas.

### Benchmark real por engine (baseline por máquina)

Para medir engines reais (Edge/Piper/Coqui) com capítulos curto/médio/longo e salvar baseline local:

```bash
python scripts/real_engine_benchmark.py \
  --book python_app/tests/fixtures/epubs/sample_multilang.epub \
  --engines edge,piper,coqui
```

Arquivos gerados em `.cache/telemetry/`:
- `real-engine-benchmark-<hostname>.json` (execução atual)
- `real-engine-baseline-<hostname>.json` (baseline persistente da máquina)

Engines indisponíveis são marcadas como falha no relatório, sem interromper as demais.

### Métricas de otimização no dashboard

`metrics-summary.json` e `metrics-dashboard.html` agora incluem:

- `prefetch_hit_rate`: taxa de acerto do prefetch de capítulo
- `ab_explorations`: quantas explorações A/B ocorreram em `--engine auto`
- `budget_caps_applied`: quantas vezes o budget de recursos reduziu paralelismo
- `adaptive_state_restores`: quantas restaurações de checkpoint adaptativo ocorreram
- `thermal_guard_cap`: quantas vezes o guard térmico/energia reduziu paralelismo
- `segment_success` / `pre_segment_check`: eventos detalhados em `_segment_metrics.jsonl`
- `segment-metrics-summary.json` / `segment-metrics-engine-chapter.csv`: agregados por engine/capítulo
- `segment-metrics-dashboard.html`: visão rápida visual dos segmentos
- `metrics-recommendations.txt`: recomendações automáticas pós-run
  - inclui percentis (P50/P95) e jitter para detectar instabilidade real

### Troubleshooting Edge (DNS/SSL/429)

Se o Edge-TTS ficar instável no ambiente atual:

- **DNS/SSL (`ClientConnectorDNSError`, certificado)**:
  - valide conectividade externa no host
  - reduza concorrência:
    - `EDGE_MAX_CONCURRENCY=1`
    - `CHAPTER_PARALLEL_COUNT=1`
  - habilite fallback automático para local:
    - `--engine auto` (com Piper/Coqui instalados)
- **429 / rate limit / throttle**:
  - reduza carga:
    - `EDGE_MAX_CONCURRENCY=1..2`
    - `EDGE_CHUNK_CHARS=4000..9000`
  - mantenha auto-tune ligado (`--edge-auto-tune`)
  - habilite rotação de identidade/voz em throttling:
    - `EDGE_IDENTITY_ROTATION_ENABLED=true`
    - `EDGE_IDENTITY_VOICES=pt-BR-FranciscaNeural,pt-BR-AntonioNeural,en-US-JennyNeural`
- **timeouts frequentes**:
  - aumentar tolerância:
    - `EDGE_MAX_SEGMENT_SECONDS=90..120`
    - `CHAPTER_STALL_SECONDS=60`
  - usar perfil estável:
    - `--edge-stable-mode`

Para investigação rápida:

```bash
python -m python_app.main convert book.epub --engine edge --chapter 1 --no-parallel --verbose
```

Se falhar, rode com `--engine auto` para permitir recuperação por engine local.

### CI benchmark noturno

O repositório inclui workflow agendado (`.github/workflows/nightly-benchmark.yml`) que:

- roda benchmark de velocidade diário
- compara com baseline e aplica gate de regressão
- publica artefatos JSON
- abre issue automaticamente em caso de regressão

Também há o workflow de PR (`.github/workflows/feature-ab-regression.yml`) que:

- roda benchmark A/B das features (`stage-pipeline` + `external_worker_pool`)
- aplica gate de regressão com thresholds configuráveis
- publica artefato JSON com os resultados

E o workflow semanal (`.github/workflows/weekly-feature-history.yml`) que:

- roda benchmark A/B semanal
- atualiza histórico rolling (`feature-ab-history.json`) via cache do GitHub Actions
- executa smoke de estabilidade longa (`scripts/long_stability_smoke.py`)
- roda análise de tendência (`scripts/check_benchmark_history_trend.py`) para detectar regressão sustentada
- publica relatório Markdown resumido (`feature-ab-history.md`) no Step Summary do Actions

Para histórico de mudanças desta release, veja `CHANGELOG.md`.

## API Server

```bash
# Start FastAPI server
python app.py

# Or via uvicorn
uvicorn app:app --host 0.0.0.0 --port 8000
```

### API Endpoints

- `POST /api/convert` - Upload EPUB and start conversion
- `GET /api/jobs/{job_id}` - Check conversion status
- `POST /api/jobs/{job_id}/cancel` - Cancel a queued/running job
- `GET /api/jobs/resumable` - List resumable jobs
- `GET /api/outputs/{job_id}/{filename}` - Download output file
- `GET /api/health` - Health check
- `POST /api/cleanup` - Cleanup old files (R2 + local)
- `GET /api/voices` - Dynamic list of curated voices/models for the frontend
- `GET /api/telemetry` - Aggregated Edge/Coqui/Piper throughput (chars/s)
- `GET /api/telemetry/segments` - Latest segment-level telemetry summary
- `GET /api/telemetry/feature-history` - Rolling Feature A/B benchmark history

#### Upload limits

Uploads are capped at **100 MB** by default to avoid long-running requests on Hugging Face Spaces. Override the limit by setting:

```

Telemetry artifacts are auto-cleaned by retention (`TELEMETRY_RETENTION_HOURS`, default 720h / 30 days).
# Backend (FastAPI)
export MAX_UPLOAD_MB=120

# Frontend build (Vite)
export VITE_MAX_UPLOAD_MB=120
```

Both variables should match so the UI can warn users before hitting the server.

### Optional: Configure R2 Storage (Recommended)

By default, files are stored locally in `/tmp` and lost on server restart.

For **permanent storage** with Cloudflare R2 (10 GB free):

📖 **[Complete R2 Setup Guide](docs/R2_SETUP.md)**

Quick summary:
1. Create free Cloudflare account
2. Create R2 bucket
3. Get API credentials
4. Set environment variables in Hugging Face Secrets:
   - `R2_ACCOUNT_ID`
   - `R2_ACCESS_KEY_ID`
   - `R2_SECRET_ACCESS_KEY`
   - `R2_BUCKET_NAME`
   - `R2_PUBLIC_URL`

Benefits:
- ✅ Files persist across server restarts
- ✅ 10 GB free storage
- ✅ Free downloads (no egress fees)
- ✅ Global CDN

### Model Cache (Coqui + Piper)

- Coqui downloads now live under `.cache/coqui_models`
- Piper models download to `.cache/piper_models` (or `PIPER_MODEL_DIR`)
- `TTS_HOME`, `COQUI_TTS_CACHE_DIR` and `PIPER_MODEL_DIR` are configured automatically so HF Spaces reuse the same files between conversions

### Telemetry & Benchmarks

- Every converted chapter records actual chars/second for the engine.
- Aggregated stats are stored in `.cache/telemetry/engine_samples.json` and exposed via `/api/telemetry`.
- Auto mode uses these measurements to prioritise the fastest engine for future chapters automatically.

## Available Voices

### Edge-TTS (PT-BR)
- **Female**: Francisca, Brenda, Elza, Giovanna, Leila, Leticia, Manuela, Yara
- **Male**: Antonio, Donato, Fabio, Humberto, Julio, Nicolau, Valerio

### Piper (Local)
- `pt_BR-faber-medium` (recommended)
- `pt_BR-edresson-low`

## Project Structure

```
Epub-to-Mp3/
├── app.py              # HF Space entry point (FastAPI)
├── requirements.txt    # Dependencies
├── python_app/
│   ├── main.py         # CLI entry point
│   ├── server.py       # FastAPI server
│   ├── models/         # Piper ONNX models
│   ├── src/
│   │   ├── config.py
│   │   ├── converter.py
│   │   ├── ebook_reader.py
│   │   ├── cache_manager.py
│   │   └── tts/        # TTS engine implementations
│   └── tests/
└── .github/workflows/  # CI + HF sync
```

## License

MIT
