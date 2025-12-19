# 🚀 ./convert - One-Command Turbo Conversion

## Quick Start

Convert any EPUB/PDF to audiobook with maximum speed in one command:

```bash
./convert book.epub
```

## Features

✅ **Auto Hardware Detection**
- Detects your CPU, RAM, GPU automatically
- Optimizes settings for your specific hardware
- No manual configuration needed

✅ **Turbo Mode by Default**
- Maximum speed settings pre-configured
- Smart engine selection (auto mode)
- Parallel processing enabled when beneficial

✅ **Verbose Output**
- Shows hardware profile on startup
- Real-time progress with ETA
- Performance metrics and speed

✅ **Smart & Safe**
- Validates file exists before starting
- Graceful error handling
- Respects API rate limits

## Usage Examples

### Basic conversion (entire book):
```bash
./convert "my-book.epub"
```

### Single chapter:
```bash
./convert book.epub --chapter 5
```

### With path:
```bash
./convert "/Users/you/Downloads/book.pdf"
```

### Preview structure first:
```bash
python -m python_app.main book.epub --show-structure
./convert book.epub  # Then convert
```

## What Happens Automatically

1. **Hardware Detection** (startup):
   - Detects CPU cores, frequency, brand
   - Checks available RAM
   - Identifies GPU (dedicated vs integrated)
   - Calculates performance tier
   - Sets optimal EDGE_MAX_CONCURRENCY

2. **Engine Optimization**:
   - Uses `--engine auto` for smart selection
   - Continuously monitors performance
   - Switches engines if one underperforms
   - Adapts to current conditions

3. **Verbose Monitoring**:
   - Shows hardware profile at startup
   - Displays real-time conversion progress
   - Shows speed (chars/s) and ETA
   - Reports final conversion time

## Example Output

```
╔════════════════════════════════════════════════════════════╗
║  🚀 EPUB/PDF TO MP3 CONVERTER - TURBO MODE               ║
╚════════════════════════════════════════════════════════════╝

============================================================
🖥️  HARDWARE PROFILE & AUTO-OPTIMIZATION
============================================================

💻 CPU:
   Model: Intel(R) Core(TM) i5-8259U CPU @ 2.30GHz
   Cores: 4 physical, 8 logical
   Frequency: 2300 MHz

🧠 RAM:
   Total: 8.0 GB
   Available: 2.5 GB

🎮 GPU:
   Type: Intel Iris Plus Graphics 655
   Status: ❌ No dedicated GPU

🌐 Platform:
   OS: Darwin
   Network: Fast

⚡ Performance Tier: High (Enthusiast)

⚙️  OPTIMIZATIONS:
   EDGE_MAX_CONCURRENCY: 6
   Parallel Processing: ✅ Enabled
   Strategy: Balanced aggressive for high performance

============================================================

📖 Livro: Dom Quixote
👤 Autor: Miguel de Cervantes

Convertendo capítulos: [██████████████] 100.00% (60/60)
✅ [EDGE] Capítulo 1 → 61s (229 chars/s)
...

✅ Conversão concluída em 1h 2m 15s

╔════════════════════════════════════════════════════════════╗
║  ✅ CONVERSION COMPLETE!                                  ║
╚════════════════════════════════════════════════════════════╝
```

## Performance

Your Mac Intel i5 without dedicated GPU is classified as **High (Enthusiast)** tier:

- **EDGE_MAX_CONCURRENCY**: 6 (automatically set)
- **Expected Speed**: ~230-310 chars/s
- **Typical Chapter**: ~1 minute (14k chars)
- **Full Book (60 chapters)**: ~1 hour

## Manual Override

If you want to override auto-detection:

```bash
# Force lower concurrency (slower connection)
EDGE_MAX_CONCURRENCY=4 ./convert book.epub

# Force higher concurrency (faster connection)
EDGE_MAX_CONCURRENCY=8 ./convert book.epub

# Disable parallel processing
python -m python_app.main book.epub --verbose --no-parallel
```

## Troubleshooting

### "File not found" error:
- Check file path is correct
- Use quotes for paths with spaces: `./convert "my book.epub"`

### Slow conversion:
- Check internet connection (Edge-TTS requires internet)
- Try `--engine piper` for offline conversion
- Lower EDGE_MAX_CONCURRENCY if getting timeouts

### Want more control:
- Use direct CLI: `python -m python_app.main book.epub --help`
- Use interactive menu: `python -m python_app.main menu`

## Advanced CLI Options

All main.py flags work with ./convert:

```bash
./convert book.epub --chapter 5                    # Single chapter
./convert book.epub --start 10 --end 20           # Chapter range
./convert book.epub --engine piper                # Specific engine
./convert book.epub --voice-gender male           # Gender preference
./convert book.epub --output-dir ./audiobooks     # Custom output
```

The script automatically adds:
- `--verbose`: For detailed output
- `--engine auto`: For smart engine selection (unless you override)

## Performance Tiers

Based on your hardware, the system assigns a performance tier:

| Tier | Score | EDGE_MAX_CONCURRENCY | Speed | Your System |
|------|-------|---------------------|-------|-------------|
| Ultra | 80+ | 8 | ~370 chars/s | |
| **High** | 60-79 | **6** | **~230-310 chars/s** | **✅ You are here** |
| Medium | 40-59 | 4 | ~180-230 chars/s | |
| Low | <40 | 2 | ~80-150 chars/s | |

Your Intel i5 with 8GB RAM scores in the **High** tier, giving you near-maximum performance.

## Summary

**One command. Maximum speed. Zero configuration.**

```bash
./convert book.epub
```

That's it! 🚀
