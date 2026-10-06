# Configuration and Performance

## Main goal

The project is optimized for throughput and aggressive CPU/RAM usage.

## Most important variables

### Edge-TTS

These supported overrides are examples for a local environment. The runtime
selects different safe values for Hugging Face Spaces and available hardware.

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

```

### Large chapter handling

```bash
MAX_CHAPTER_CHARS=0
```

### Local engines

```bash
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
