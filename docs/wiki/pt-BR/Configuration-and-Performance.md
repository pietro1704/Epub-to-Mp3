# Configuração e Performance

## Objetivo principal

O projeto privilegia throughput e uso agressivo de CPU/RAM.

## Variáveis mais importantes

### Edge-TTS

Estes overrides suportados são exemplos para ambiente local. O runtime usa
valores seguros diferentes no Hugging Face Spaces e conforme o hardware.

```bash
EDGE_CHUNK_CHARS=12000
EDGE_MAX_CONCURRENCY=12
EDGE_MAX_SEGMENT_SECONDS=85
CHAPTER_PARALLEL_COUNT=0
```

### Detecção de lentidão / fallback

```bash
EDGE_MIN_CHARS_PER_SECOND=45
EDGE_SLOW_RATIO_THRESHOLD=2.5

```

### Capítulos grandes

```bash
MAX_CHAPTER_CHARS=0
```

### Engines locais

```bash

PIPER_MAX_PROCS=0
```

## Perfis especiais

Em Hugging Face Spaces, o projeto reduz paralelismo e endurece timeouts para sobreviver melhor ao ambiente compartilhado.

## Cache

O cache evita:

- reparsear o mesmo livro
- retrabalho entre runs
- custos desnecessários em fallback e validação

## Telemetria

O sistema mede desempenho por engine e usa esses dados para melhorar ETA e ordem de fallback no servidor web.

## Boas práticas

- deixe `CHAPTER_PARALLEL_COUNT=0` para auto scale
- só reduza concorrência quando houver rate limit ou recursos limitados
- use `MAX_CHAPTER_CHARS` para livros com capítulos anômalos
