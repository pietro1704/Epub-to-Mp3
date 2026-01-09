#!/usr/bin/env python3
"""
Benchmark: Edge-TTS Optimization Configurations

Compares different Edge-TTS configurations to find optimal settings:
1. Baseline (no optimizations) - fixed 2000 chars, no parallel, no warmup
2. Conservative - 4000 chars, 4 concurrent, warmup
3. Balanced - 6000 chars, 8 concurrent, warmup
4. Aggressive - 8000 chars, 8 concurrent, warmup
5. Maximum - 10000 chars, 8 concurrent, warmup

Tests measure:
- Speed (characters per second)
- Reliability (success rate)
- Error recovery (rate limit handling)
"""

import asyncio
import importlib.util
import os
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional

# Add parent to path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


@dataclass
class EdgeConfig:
    """Configuration for Edge-TTS test."""

    name: str
    chunk_chars: int
    max_concurrency: int
    max_segment_seconds: int
    enable_parallel: bool
    enable_warmup: bool
    description: str


@dataclass
class BenchmarkResult:
    config_name: str
    total_chars: int
    total_time: float
    chars_per_second: float
    success_rate: float
    successes: int
    failures: int
    errors: List[str]
    warmup_time: float


# Test configurations
CONFIGURATIONS = [
    EdgeConfig(
        name="1. Baseline (no optimization)",
        chunk_chars=2000,
        max_concurrency=1,
        max_segment_seconds=30,
        enable_parallel=False,
        enable_warmup=False,
        description="Fixed 2K chunks, sequential, no warmup",
    ),
    EdgeConfig(
        name="2. Conservative",
        chunk_chars=4000,
        max_concurrency=4,
        max_segment_seconds=45,
        enable_parallel=True,
        enable_warmup=True,
        description="4K chunks, 4 concurrent, warmup enabled",
    ),
    EdgeConfig(
        name="3. Balanced (default)",
        chunk_chars=6000,
        max_concurrency=8,
        max_segment_seconds=45,
        enable_parallel=True,
        enable_warmup=True,
        description="6K chunks, 8 concurrent, warmup enabled",
    ),
    EdgeConfig(
        name="4. Aggressive",
        chunk_chars=8000,
        max_concurrency=8,
        max_segment_seconds=65,
        enable_parallel=True,
        enable_warmup=True,
        description="8K chunks, 8 concurrent, warmup enabled",
    ),
    EdgeConfig(
        name="5. Maximum",
        chunk_chars=10000,
        max_concurrency=8,
        max_segment_seconds=85,
        enable_parallel=True,
        enable_warmup=True,
        description="10K chunks, 8 concurrent, warmup enabled",
    ),
]

# Test texts of varying lengths
TEST_TEXTS = {
    "short": "Este é um texto curto para teste. A conversão de texto em fala é uma tecnologia incrível.",
    "medium": """
A inteligência artificial está transformando o mundo de maneiras que antes pareciam impossíveis.
Desde assistentes virtuais até carros autônomos, as aplicações são infinitas.
O aprendizado de máquina permite que os computadores aprendam com dados e melhorem continuamente.
Redes neurais profundas podem reconhecer padrões complexos em imagens, texto e áudio.
O futuro promete ainda mais avanços, com a IA sendo integrada em cada aspecto de nossas vidas.
""".strip(),
    "long": """
A história da computação é fascinante e repleta de inovações que mudaram o mundo.
Desde os primeiros computadores mecânicos de Charles Babbage até os supercomputadores modernos,
a evolução foi extraordinária. Alan Turing, considerado o pai da ciência da computação,
desenvolveu conceitos fundamentais que ainda são usados hoje.

Os primeiros computadores eletrônicos, como o ENIAC, ocupavam salas inteiras e consumiam
enormes quantidades de energia. Hoje, um smartphone tem mais poder de processamento do que
todos os computadores que existiam na década de 1960 combinados.

A revolução da internet conectou bilhões de pessoas ao redor do mundo, criando uma nova
era de comunicação e compartilhamento de informações. O comércio eletrônico, as redes sociais
e os serviços de streaming transformaram completamente a forma como vivemos e trabalhamos.

A inteligência artificial representa a próxima grande fronteira. Sistemas de aprendizado
de máquina podem agora traduzir idiomas em tempo real, diagnosticar doenças com precisão
comparável a médicos especialistas, e criar arte e música originais. O potencial é ilimitado.

À medida que avançamos para o futuro, questões éticas e de privacidade tornam-se cada vez
mais importantes. Como sociedade, precisamos garantir que a tecnologia seja desenvolvida
e utilizada de forma responsável, beneficiando a todos e não apenas alguns privilegiados.
""".strip(),
}


class EdgeEngineBaseline:
    """Minimal Edge-TTS wrapper without optimizations for baseline testing."""

    def __init__(self, voice: str, chunk_chars: int = 2000):
        self.voice = voice
        self.chunk_chars = chunk_chars

    async def synthesize_async(self, text: str, output_path: Path) -> Optional[Path]:
        """Simple sequential synthesis without optimizations."""
        import edge_tts

        try:
            communicate = edge_tts.Communicate(text, self.voice)
            await communicate.save(str(output_path))
            return output_path if output_path.exists() else None
        except Exception as e:
            print(f"Baseline error: {e}")
            return None


async def run_configuration(
    config: EdgeConfig,
    texts: Dict[str, str],
    voice: str = "pt-BR-ThalitaMultilingualNeural",
) -> BenchmarkResult:
    """Test a specific Edge-TTS configuration."""
    print(f"\n{'='*60}")
    print(f"Testing: {config.name}")
    print(f"Config: {config.description}")
    print(f"{'='*60}")

    total_chars = 0
    total_time = 0
    successes = 0
    failures = 0
    errors = []
    warmup_time = 0

    if config.enable_warmup and config.enable_parallel:
        # Use the optimized engine
        from src.config import ConversionConfig
        from src.tts.edge_engine import reset_adaptive_settings
        from src.tts.factory import TTSFactory

        # Reset adaptive settings to start fresh
        reset_adaptive_settings()

        # Set environment variables for this config
        os.environ["EDGE_CHUNK_CHARS"] = str(config.chunk_chars)
        os.environ["EDGE_MAX_CONCURRENCY"] = str(config.max_concurrency)

        engine_config = ConversionConfig(
            engine="edge",
            voice=voice,
            primary_language="pt",
            verbose=False,
            edge_chunk_chars=config.chunk_chars,
            edge_max_segment_seconds=config.max_segment_seconds,
            edge_enable_parallel=config.enable_parallel,
        )

        factory = TTSFactory()
        engine = factory.create_engine(engine_config)

        # Warmup phase
        warmup_start = time.perf_counter()
        with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as f:
            warmup_path = Path(f.name)
        try:
            await engine.synthesize_async("Teste de aquecimento.", warmup_path)
        except Exception:
            pass
        finally:
            if warmup_path.exists():
                warmup_path.unlink()
        warmup_time = time.perf_counter() - warmup_start
        print(f"  Warmup completed in {warmup_time:.2f}s")

    else:
        # Use baseline engine
        engine = EdgeEngineBaseline(voice, config.chunk_chars)

    # Test each text
    for text_name, text in texts.items():
        print(f"\n  Testing '{text_name}' ({len(text)} chars)...")

        with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as f:
            output_path = Path(f.name)

        try:
            start = time.perf_counter()
            result = await engine.synthesize_async(text, output_path)
            elapsed = time.perf_counter() - start

            if result and output_path.exists() and output_path.stat().st_size > 0:
                total_time += elapsed
                total_chars += len(text)
                successes += 1
                speed = len(text) / elapsed
                print(f"    ✅ Success: {elapsed:.2f}s ({speed:.1f} chars/s)")
            else:
                failures += 1
                errors.append(f"{text_name}: Empty output")
                print("    ❌ Failed: Empty output")

        except Exception as e:
            failures += 1
            error_msg = str(e)[:100]
            errors.append(f"{text_name}: {error_msg}")
            print(f"    ❌ Error: {error_msg}")

        finally:
            if output_path.exists():
                output_path.unlink()

    # Calculate results
    chars_per_second = total_chars / total_time if total_time > 0 else 0
    success_rate = successes / (successes + failures) if (successes + failures) > 0 else 0

    return BenchmarkResult(
        config_name=config.name,
        total_chars=total_chars,
        total_time=total_time,
        chars_per_second=chars_per_second,
        success_rate=success_rate,
        successes=successes,
        failures=failures,
        errors=errors,
        warmup_time=warmup_time,
    )


async def run_rate_limit_recovery(voice: str = "pt-BR-ThalitaMultilingualNeural"):
    """Test rate limit recovery behavior with long text."""
    print("\n" + "=" * 60)
    print("Testing Rate Limit Recovery (long text)")
    print("=" * 60)

    # Very long text to potentially trigger rate limits
    long_text = TEST_TEXTS["long"] * 3  # ~4500 chars

    results = {}

    # Test baseline (no recovery)
    print("\n  Testing Baseline (no rate limit handling)...")
    engine = EdgeEngineBaseline(voice, 2000)
    with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as f:
        output_path = Path(f.name)
    try:
        start = time.perf_counter()
        result = await engine.synthesize_async(long_text, output_path)
        elapsed = time.perf_counter() - start
        if result and output_path.exists():
            results["baseline"] = {
                "success": True,
                "time": elapsed,
                "chars_per_second": len(long_text) / elapsed,
            }
            print(f"    ✅ Success: {elapsed:.2f}s ({len(long_text)/elapsed:.1f} chars/s)")
        else:
            results["baseline"] = {"success": False, "error": "Empty output"}
            print("    ❌ Failed: Empty output")
    except Exception as e:
        results["baseline"] = {"success": False, "error": str(e)[:100]}
        print(f"    ❌ Error: {str(e)[:100]}")
    finally:
        if output_path.exists():
            output_path.unlink()

    # Test optimized engine (with rate limit recovery)
    print("\n  Testing Optimized (with rate limit handling)...")
    from src.config import ConversionConfig
    from src.tts.edge_engine import reset_adaptive_settings
    from src.tts.factory import TTSFactory

    reset_adaptive_settings()

    config = ConversionConfig(
        engine="edge",
        voice=voice,
        primary_language="pt",
        verbose=False,
        edge_enable_parallel=True,
    )
    factory = TTSFactory()
    engine = factory.create_engine(config)

    with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as f:
        output_path = Path(f.name)
    try:
        start = time.perf_counter()
        result = await engine.synthesize_async(long_text, output_path)
        elapsed = time.perf_counter() - start
        if result and output_path.exists():
            results["optimized"] = {
                "success": True,
                "time": elapsed,
                "chars_per_second": len(long_text) / elapsed,
            }
            print(f"    ✅ Success: {elapsed:.2f}s ({len(long_text)/elapsed:.1f} chars/s)")
        else:
            results["optimized"] = {"success": False, "error": "Empty output"}
            print("    ❌ Failed: Empty output")
    except Exception as e:
        results["optimized"] = {"success": False, "error": str(e)[:100]}
        print(f"    ❌ Error: {str(e)[:100]}")
    finally:
        if output_path.exists():
            output_path.unlink()

    return results


def print_summary(results: List[BenchmarkResult], rate_limit_results: dict):
    """Print benchmark summary."""
    print("\n" + "=" * 80)
    print("BENCHMARK SUMMARY: Edge-TTS Optimization Configurations")
    print("=" * 80)

    print("\n" + "-" * 80)
    print(f"{'Configuration':<35} {'Chars/s':<10} {'Success':<10} {'Total Time':<12} {'Warmup':<8}")
    print("-" * 80)

    # Sort by chars_per_second
    sorted_results = sorted(results, key=lambda x: x.chars_per_second, reverse=True)

    for r in sorted_results:
        warmup_str = f"{r.warmup_time:.1f}s" if r.warmup_time > 0 else "N/A"
        print(
            f"{r.config_name:<35} {r.chars_per_second:<10.1f} {r.success_rate*100:<9.0f}% {r.total_time:<11.2f}s {warmup_str:<8}"
        )
        if r.errors:
            for e in r.errors[:2]:
                print(f"   ⚠️ {e[:60]}")

    # Find best configuration
    best = sorted_results[0]
    print("\n" + "=" * 80)
    print(f"🏆 BEST CONFIGURATION: {best.config_name}")
    print(f"   Speed: {best.chars_per_second:.1f} chars/s")
    print(f"   Success Rate: {best.success_rate*100:.0f}%")
    print("=" * 80)

    # Rate limit recovery results
    print("\n" + "-" * 80)
    print("Rate Limit Recovery Test:")
    print("-" * 80)
    for name, result in rate_limit_results.items():
        if result.get("success"):
            print(f"  {name}: ✅ {result['chars_per_second']:.1f} chars/s ({result['time']:.2f}s)")
        else:
            print(f"  {name}: ❌ {result.get('error', 'Unknown error')}")

    # Recommendations
    print("\n" + "=" * 80)
    print("📋 RECOMMENDATIONS:")
    print("=" * 80)

    # Find configs with 100% success
    reliable_configs = [r for r in sorted_results if r.success_rate >= 1.0]
    if reliable_configs:
        fastest_reliable = reliable_configs[0]
        print(f"\n  For RELIABILITY: Use '{fastest_reliable.config_name}'")
        print(f"     - 100% success rate at {fastest_reliable.chars_per_second:.1f} chars/s")

    # Overall best
    if best.success_rate >= 0.9:
        print(f"\n  For SPEED: Use '{best.config_name}'")
        print(
            f"     - {best.chars_per_second:.1f} chars/s with {best.success_rate*100:.0f}% success"
        )
    else:
        print(f"\n  ⚠️ Best speed config has low reliability ({best.success_rate*100:.0f}%)")

    # Default recommendation
    balanced = next((r for r in results if "Balanced" in r.config_name), None)
    if balanced:
        print(f"\n  DEFAULT RECOMMENDATION: '{balanced.config_name}'")
        print(
            f"     - Good balance of speed ({balanced.chars_per_second:.1f} chars/s) and reliability ({balanced.success_rate*100:.0f}%)"
        )


async def main():
    """Run the Edge-TTS optimization benchmark."""
    print("🔬 Edge-TTS Optimization Benchmark")
    print("=" * 80)
    print("Testing different configurations to find optimal settings")
    print("=" * 80)

    # Check Edge-TTS availability
    if importlib.util.find_spec("edge_tts") is not None:
        print("✅ Edge-TTS: Available")
    else:
        print("❌ Edge-TTS not installed!")
        return

    results = []

    # Test each configuration
    for config in CONFIGURATIONS:
        try:
            result = await run_configuration(config, TEST_TEXTS)
            results.append(result)
        except Exception as e:
            print(f"❌ Configuration '{config.name}' failed: {e}")
            results.append(
                BenchmarkResult(
                    config_name=config.name,
                    total_chars=0,
                    total_time=0,
                    chars_per_second=0,
                    success_rate=0,
                    successes=0,
                    failures=len(TEST_TEXTS),
                    errors=[str(e)],
                    warmup_time=0,
                )
            )

        # Small delay between configs to avoid rate limits
        await asyncio.sleep(2)

    # Test rate limit recovery
    rate_limit_results = await run_rate_limit_recovery()

    # Print summary
    print_summary(results, rate_limit_results)


if __name__ == "__main__":
    asyncio.run(main())
