# 🎯 Auto-Tuning de Performance

Sistema automático que detecta hardware e rede, ajustando configurações de performance em tempo real.

## 🚀 Funcionalidades

### Detecção Automática
- **CPU**: Cores físicos, threads, frequência
- **RAM**: Total e disponível
- **GPU**: CUDA, Metal ou CPU
- **Storage**: SSD vs HDD
- **Rede**: Velocidade (Mbps) e latência (ms)

### Perfis Automáticos

#### 🐌 Conservative
- **Quando**: CPU < 4 cores OU RAM < 8GB OU rede lenta
- **Edge-TTS**: Concurrency=2, Chunk=4000
- **Melhor para**: Estabilidade máxima

#### ⚖️ Balanced (Padrão)
- **Quando**: CPU 4-8 cores, RAM 8-16GB, rede média
- **Edge-TTS**: Concurrency=4, Chunk=8000
- **Melhor para**: Equilíbrio velocidade/estabilidade

#### 🚀 Performance
- **Quando**: CPU > 8 cores OU RAM > 16GB OU rede rápida
- **Edge-TTS**: Concurrency=8, Chunk=10000  
- **Melhor para**: Conversões rápidas

#### ⚡ Maximum
- **Quando**: CPU > 12 cores, RAM > 24GB, rede ultra, GPU disponível
- **Edge-TTS**: Concurrency=12, Chunk=12000
- **Melhor para**: Máxima velocidade

## 📊 Uso

### Automático (Padrão)
```bash
# Auto-tuning ativado por padrão no converter e server
python -m python_app.main livro.epub  # Detecta e aplica automaticamente
python -m uvicorn python_app.server:app  # Servidor aplica no startup
```

### Visualizar Configuração
```bash
# Ver config atual (sem medir rede)
python show_autotuning.py

# Medir rede também (adiciona ~3s)
python show_autotuning.py --measure

# Aplicar configurações
python show_autotuning.py --measure --apply
```

### Desabilitar
```bash
# Desabilitar temporariamente
export ENABLE_AUTO_TUNING=0
python -m python_app.main livro.epub

# Ou no código
config.extra["auto_tuning_disabled"] = True
```

### Configuração Manual (Override)
```bash
# Sobrescreve auto-tuning
export EDGE_MAX_CONCURRENCY=16
export EDGE_CHUNK_CHARS=15000
export COQUI_MAX_WORKERS=4
python -m python_app.main livro.epub
```

## 🔧 Variáveis de Ambiente

### Auto-Tuning
- `ENABLE_AUTO_TUNING=1` - Habilita/desabilita (padrão: habilitado)
- `AUTO_TUNE_MEASURE_NETWORK=1` - Medir rede no CLI (padrão: habilitado)

### Edge-TTS (configuradas automaticamente)
- `EDGE_MAX_CONCURRENCY` - Requisições paralelas
- `EDGE_CHUNK_CHARS` - Tamanho dos chunks
- `EDGE_SAFE_CHAPTER_PARALLEL` - Capítulos paralelos
- `EDGE_MAX_SEGMENT_SECONDS` - Duração máxima dos segmentos

### Coqui TTS (configuradas automaticamente)
- `COQUI_MAX_WORKERS` - Workers paralelos
- `COQUI_CHUNK_CHARS` - Tamanho dos chunks

### Kokoro TTS (configuradas automaticamente)
- `KOKORO_MAX_WORKERS` - Workers paralelos
- `KOKORO_CHUNK_CHARS` - Tamanho dos chunks

### Spark TTS (configuradas automaticamente)
- `SPARK_MAX_WORKERS` - Workers paralelos
- `SPARK_CHUNK_CHARS` - Tamanho dos chunks

## 📝 Exemplo de Output

```
======================================================================
🖥️  HARDWARE DETECTADO
======================================================================
CPU: 8 cores físicos, 16 threads
     3500 MHz
RAM: 24.0 GB disponível / 32.0 GB total
GPU: NVIDIA RTX 4090 (CUDA)
Storage: SSD
Platform: Linux
======================================================================

🌐 Medindo velocidade de rede...
   Velocidade: 120.5 Mbps
   Latência: 28.3 ms
   🎯 Tier de rede: FAST

======================================================================
🎯 PERFIL DE PERFORMANCE AUTO-CONFIGURADO: PERFORMANCE
======================================================================
Descrição: Boa conexão e hardware potente

Edge-TTS:
  EDGE_MAX_CONCURRENCY: 8
  EDGE_CHUNK_CHARS: 10000
  EDGE_SAFE_CHAPTER_PARALLEL: 4
  EDGE_MAX_SEGMENT_SECONDS: 85.0

Coqui TTS:
  COQUI_MAX_WORKERS: 3
  COQUI_CHUNK_CHARS: 2000

Kokoro TTS:
  KOKORO_MAX_WORKERS: 3
  KOKORO_CHUNK_CHARS: 2500
======================================================================
```

## 🎯 Recomendações

### Para melhorar performance:
1. **Upgrade de Internet**: Maior impacto na velocidade Edge-TTS
2. **Mais RAM**: Permite mais workers paralelos
3. **SSD**: Melhora cache e I/O
4. **GPU CUDA**: Acelera Coqui e Kokoro TTS

### Troubleshooting:
- **Conversão lenta**: Verifique tier de rede com `python show_autotuning.py --measure`
- **Out of memory**: Auto-tuner reduz workers automaticamente se RAM < 4GB disponível
- **Timeouts**: Auto-tuner reduz concurrency se rede lenta (tier: slow)

## 🏗️ Arquitetura

```
converter.py
    ↓ (chama _initialize_auto_tuning)
AutoTuner
    ↓ (usa)
HardwareMonitor
    ↓ (detecta)
HardwareSpecs + NetworkStats
    ↓ (seleciona)
TuningProfile
    ↓ (aplica)
Environment Variables (EDGE_*, COQUI_*, etc.)
```

## 📚 Módulos

- `python_app/src/hardware_monitor.py` - Detecta HW e rede
- `python_app/src/auto_tuner.py` - Seleciona e aplica perfis
- `show_autotuning.py` - Script CLI para visualização
- `python_app/tests/test_auto_tuner.py` - Testes unitários

---

**Nota**: O auto-tuning **não sobrescreve** variáveis já setadas manualmente, a menos que `force=True` seja usado.
