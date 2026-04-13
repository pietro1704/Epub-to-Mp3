# Configuration and Performance

## Main goal

The project is optimized for throughput and aggressive CPU/RAM usage.

## Most important variables

### Edge-TTS

```bash
EDGE_CHUNK_CHARS=12000
EDGE_MAX_CONCURRENCY=12
EDGE_MAX_SEGMENT_SECONDS=85
CHAPTER_PARALLEL_COUNT=0
```

### Slow detection and fallback

```bash
EDGE_MIN_CHARS_PER_SECOND=45
EDGE_SLOW_RATIO_THRESHOLD=2.5
_CHAPTER_TIMEOUT_MAX=300
```

### Large chapter handling

```bash
MAX_CHAPTER_CHARS=0
```

### Local engines

```bash
KOKORO_MAX_WORKERS=0
PIPER_MAX_PROCS=0
```

## Special runtime profiles

In Hugging Face Spaces, the project uses a more conservative runtime profile for concurrency and timeouts.

## Cache

The cache avoids:

- re-parsing the same book
- repeated work across runs
- unnecessary fallback and validation cost

## Telemetry

The system records engine performance and uses it to improve ETA and engine ordering in the web server.
