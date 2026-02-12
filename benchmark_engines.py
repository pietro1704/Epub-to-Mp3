#!/usr/bin/env python3
"""
Benchmark script: compare TTS engines on speed, CPU and RAM usage.

Usage:
    source .venv/bin/activate
    python benchmark_engines.py <file.epub> [--engines edge,kokoro,piper] [--chapters 3]
"""

import argparse
import asyncio
import os
import sys
import time
from pathlib import Path

import psutil

# Ensure python_app is importable
sys.path.insert(0, str(Path(__file__).parent))

from python_app.src.config import AppConfig
from python_app.src.converter import AudioConverter
from python_app.src.ebook_reader import EbookReader
from python_app.src.i18n import get_localization


def get_system_info():
    cpu_count_logical = os.cpu_count() or 1
    cpu_count_physical = psutil.cpu_count(logical=False) or cpu_count_logical
    mem = psutil.virtual_memory()
    print("=" * 60)
    print("SYSTEM INFO")
    print(f"  CPU cores: {cpu_count_physical} physical, {cpu_count_logical} logical")
    print(
        f"  RAM: {mem.total / (1024**3):.1f} GB total, {mem.available / (1024**3):.1f} GB available"
    )
    print(f"  Platform: {sys.platform}")
    print("=" * 60)


def monitor_resources(proc, interval=0.5):
    """Collect CPU and memory samples for a process."""
    samples = {"cpu": [], "rss_mb": [], "timestamps": []}

    def _sample():
        try:
            cpu = proc.cpu_percent(interval=None)
            mem = proc.memory_info().rss / (1024 * 1024)
            samples["cpu"].append(cpu)
            samples["rss_mb"].append(mem)
            samples["timestamps"].append(time.time())
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass

    return samples, _sample


async def benchmark_engine(
    engine_name: str,
    epub_path: Path,
    max_chapters: int,
    env_overrides: dict,
):
    """Run conversion with one engine and measure performance."""
    # Apply env overrides
    old_env = {}
    for k, v in env_overrides.items():
        old_env[k] = os.environ.get(k)
        os.environ[k] = str(v)

    try:
        app_config = AppConfig()
        config = app_config.create_conversion_config(
            engine=engine_name,
            verbose=True,
            auto_validate_output=False,
            auto_fix_output=False,
            validate_audio=False,
            verify_transcription=False,
            clear_cache=True,
        )

        loc = get_localization()
        converter = AudioConverter(localization=loc)
        reader = EbookReader()
        chapters = reader.extract_chapters(str(epub_path))

        if max_chapters > 0:
            chapters = chapters[:max_chapters]

        total_chars = sum(len(ch.text or "") for ch in chapters)
        print(f"\n{'='*60}")
        print(f"ENGINE: {engine_name.upper()}")
        print(f"  Chapters: {len(chapters)}, Total chars: {total_chars:,}")
        print(
            f"  Config: chunk_chars={config.edge_chunk_chars}, concurrency={config.edge_max_concurrency}"
        )

        proc = psutil.Process(os.getpid())
        mem_before = proc.memory_info().rss / (1024 * 1024)
        cpu_times_before = proc.cpu_times()

        t0 = time.perf_counter()

        # Run conversion
        result = await converter.convert(str(epub_path), config, chapters=chapters)

        elapsed = time.perf_counter() - t0
        cpu_times_after = proc.cpu_times()
        mem_after = proc.memory_info().rss / (1024 * 1024)

        cpu_user = cpu_times_after.user - cpu_times_before.user
        cpu_system = cpu_times_after.system - cpu_times_before.system
        cpu_total = cpu_user + cpu_system
        cpu_utilization = (cpu_total / elapsed * 100) if elapsed > 0 else 0

        chars_per_sec = total_chars / elapsed if elapsed > 0 else 0

        print("\n  RESULTS:")
        print(f"  Time: {elapsed:.1f}s")
        print(f"  Throughput: {chars_per_sec:.0f} chars/s")
        print(f"  CPU time: {cpu_total:.1f}s (user={cpu_user:.1f}s, sys={cpu_system:.1f}s)")
        print(f"  CPU utilization: {cpu_utilization:.0f}%")
        print(
            f"  RAM delta: {mem_after - mem_before:+.0f} MB (before={mem_before:.0f}, after={mem_after:.0f})"
        )
        print(
            f"  Success: {result.success}, Converted: {result.converted_chapters}/{result.total_chapters}"
        )
        if result.errors:
            print(f"  Errors: {result.errors[:3]}")
        print(f"{'='*60}")

        return {
            "engine": engine_name,
            "elapsed": elapsed,
            "chars_per_sec": chars_per_sec,
            "cpu_utilization": cpu_utilization,
            "ram_delta_mb": mem_after - mem_before,
            "success": result.success,
            "converted": result.converted_chapters,
            "total": result.total_chapters,
        }
    finally:
        # Restore env
        for k, v in old_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


def get_engine_env(engine: str) -> dict:
    """Return env overrides to maximize CPU/RAM usage per engine."""
    cpu = os.cpu_count() or 4
    if engine == "edge":
        return {
            "EDGE_MAX_CONCURRENCY": str(min(16, cpu * 2)),
            "EDGE_SAFE_CHAPTER_PARALLEL": str(min(8, cpu)),
            "CHAPTER_PARALLEL_COUNT": str(min(6, cpu)),
            "EDGE_CHUNK_CHARS": "12000",
        }
    elif engine == "kokoro":
        return {
            "KOKORO_MAX_WORKERS": str(max(2, cpu // 2)),
            "CHAPTER_PARALLEL_COUNT": str(max(2, cpu // 2)),
        }
    elif engine == "piper":
        return {
            "PIPER_MAX_PROCS": str(max(2, cpu)),
            "CHAPTER_PARALLEL_COUNT": str(max(2, cpu // 2)),
        }
    return {}


async def main():
    parser = argparse.ArgumentParser(description="Benchmark TTS engines")
    parser.add_argument("epub", type=Path, help="EPUB/PDF file to convert")
    parser.add_argument("--engines", default="edge,piper", help="Comma-separated engines to test")
    parser.add_argument("--chapters", type=int, default=3, help="Max chapters to convert (0=all)")
    args = parser.parse_args()

    if not args.epub.exists():
        print(f"File not found: {args.epub}")
        sys.exit(1)

    engines = [e.strip() for e in args.engines.split(",")]
    get_system_info()

    results = []
    for engine in engines:
        try:
            env = get_engine_env(engine)
            r = await benchmark_engine(engine, args.epub, args.chapters, env)
            if r:
                results.append(r)
        except Exception as e:
            print(f"\n❌ {engine} FAILED: {e}")
            import traceback

            traceback.print_exc()

    if len(results) > 1:
        print(f"\n{'='*60}")
        print("COMPARISON SUMMARY")
        print(f"{'Engine':<12} {'Time':>8} {'Chars/s':>10} {'CPU%':>8} {'RAM Δ':>8}")
        print("-" * 50)
        for r in sorted(results, key=lambda x: x["elapsed"]):
            print(
                f"{r['engine']:<12} {r['elapsed']:>7.1f}s {r['chars_per_sec']:>9.0f} "
                f"{r['cpu_utilization']:>7.0f}% {r['ram_delta_mb']:>+7.0f}MB"
            )
        print(f"{'='*60}")


if __name__ == "__main__":
    asyncio.run(main())
