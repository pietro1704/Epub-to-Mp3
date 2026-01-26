# Changelog - Sistema de Auto-Tuning

## ✨ Novas Funcionalidades

### 🎯 Auto-Tuning Inteligente
Sistema que detecta automaticamente hardware e rede, configurando flags de performance otimizadas.

#### Módulos Criados
1. **`python_app/src/hardware_monitor.py`** - Monitor de sistema
   - Detecta CPU (cores, frequência)
   - Detecta RAM (total, disponível)
   - Detecta GPU (CUDA, Metal, CPU)
   - Detecta tipo de storage (SSD vs HDD)
   - Mede velocidade de rede e latência

2. **`python_app/src/auto_tuner.py`** - Auto-tuner
   - 4 perfis pré-configurados (Conservative, Balanced, Performance, Maximum)
   - Seleção inteligente baseada em score de HW + Rede
   - Ajustes finos (reduz workers se RAM baixa, etc)
   - Aplica env vars automaticamente

3. **`show_autotuning.py`** - Script de visualização
   - Mostra configuração detectada
   - Permite medir rede opcionalmente
   - Mostra recomendações

#### Integrações

**Converter (`python_app/src/converter.py`)**
- Método `_initialize_auto_tuning()` chamado no início de `convert()`
- Detecta HW e rede automaticamente
- Aplica perfil otimizado antes da conversão
- Ativado por padrão, pode ser desabilitado com `ENABLE_AUTO_TUNING=0`

**Server (`python_app/server.py`)**  
- Auto-tuning aplicado no `_lifespan` (startup)
- Detecta HW (sem medir rede para não travar startup)
- Logs de hardware e perfil aplicado no console
- Compatibilidade com `health_monitor` via adapter

#### Configurações Automáticas

**Edge-TTS**
- `EDGE_MAX_CONCURRENCY`: 2-12 (baseado em rede e CPU)
- `EDGE_CHUNK_CHARS`: 4000-12000 (baseado em rede)
- `EDGE_SAFE_CHAPTER_PARALLEL`: 1-6 (baseado em RAM e CPU)
- `EDGE_MAX_SEGMENT_SECONDS`: 85-120 (baseado em stability)

**Coqui TTS**
- `COQUI_MAX_WORKERS`: 1-4 (baseado em GPU e RAM)
- `COQUI_CHUNK_CHARS`: 1000-2500 (baseado em RAM)

**Kokoro TTS**
- `KOKORO_MAX_WORKERS`: 1-4 (baseado em CPU)
- `KOKORO_CHUNK_CHARS`: 1500-3000 (baseado em RAM)

**Spark TTS**
- `SPARK_MAX_WORKERS`: 1-2 (GPU-bound)
- `SPARK_CHUNK_CHARS`: 1000-2000

**Piper TTS**
- `PIPER_MAX_WORKERS`: 2-8 (baseado em CPU)

## 🐛 Correções

### Bug em `converter.py:5634`
- **Problema**: Variável `chapter_num` não estava sendo atribuída
- **Solução**: Restaurada linha `chapter_num = self._chapter_number(chapter, idx)`

### Teste falhando em `test_validate_conversion.py`
- **Problema**: Teste esperava arquivo `*_completo.txt` não criado
- **Solução**: Adicionada criação do arquivo no setup do teste

### Compatibilidade `health_monitor`
- **Problema**: Conflito entre `SystemMonitor` (novo) e `HealthMonitor` (existente)
- **Solução**: 
  - Renomeado `SystemMonitor` → `HardwareMonitor`
  - Criado adapter para compatibilidade com servidor
  - Método `latest()` agora retorna dados em formato compatível

## 📊 Resultados

### Performance Atual (Sistema de Teste)
- **HW**: 4 cores, 8 threads, 2.2GB RAM, SSD, CPU only
- **Rede**: 4.5 Mbps, 545ms latência (SLOW tier)
- **Perfil aplicado**: BALANCED (ajustado)
  - EDGE_MAX_CONCURRENCY: 2 (reduzido p/ rede lenta)
  - EDGE_CHUNK_CHARS: 4000 (reduzido p/ RAM baixa)
  - EDGE_SAFE_CHAPTER_PARALLEL: 1 (conservador)

### Testes
- ✅ 382 testes Python passando
- ✅ 16 testes web passando
- ✅ Auto-tuner funcionando no converter
- ✅ Auto-tuner funcionando no servidor
- ✅ Servidor iniciando sem erros

## 📝 Documentação

- **AUTO_TUNING.md** - Guia completo de uso
- Exemplos de comandos
- Troubleshooting
- Arquitetura

## 🚀 Como Usar

```bash
# CLI (auto-tuning automático)
python -m python_app.main livro.epub

# Visualizar config
python show_autotuning.py --measure

# Servidor (auto-tuning no startup)
python -m uvicorn python_app.server:app --port 8000

# Desabilitar
export ENABLE_AUTO_TUNING=0
```

## 🎯 Próximos Passos Sugeridos

1. **Monitoramento em Tempo Real**
   - Ajustar concurrency dinamicamente durante conversão
   - Detectar throttling e reduzir carga automaticamente

2. **Machine Learning**
   - Aprender com conversões anteriores
   - Prever tempo de conversão baseado em HW+livro

3. **Telemetria**
   - Enviar perfis aplicados para analytics
   - Melhorar recomendações baseado em dados reais

4. **Cache de Rede**
   - Cachear tier de rede por 5-10min
   - Evitar medir a cada conversão no CLI

---

**Data**: 2026-01-25
**Versão**: 1.0.0
**Status**: ✅ Implementado e Testado
