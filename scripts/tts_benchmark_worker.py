"""One isolated TTS benchmark worker; no work occurs on import."""

from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path
from typing import Dict, List


def _run_worker(args: argparse.Namespace) -> int:
    import psutil

    from python_app.src.config import AppConfig, VoiceConfigProvider
    from python_app.src.ebook_reader import EbookReader
    from python_app.src.engine_pool import JobEnginePool, ResourceSnapshot
    from python_app.src.hardware_detector import HardwareProfile
    from python_app.src.tts.factory import TTSFactory

    start_ts = time.time()
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    if args.hardware_profile:
        data = json.loads(Path(args.hardware_profile).read_text(encoding="utf-8"))
        hardware_profile = HardwareProfile(**data)
    else:
        from python_app.src.hardware_detector import HardwareDetector

        hardware_profile = HardwareDetector.detect()

    reader = EbookReader(args.input_file)
    chapters = reader.get_chapter_structure(preserve_all=True)
    if args.max_chapters and args.max_chapters > 0:
        chapters = chapters[: args.max_chapters]

    primary_language = (reader.language or "auto").split("-", 1)[0]
    provider = VoiceConfigProvider()
    default_voice = (
        provider.get_voice(args.engine, primary_language)
        if primary_language
        else provider.get_voice(args.engine)
    )

    app_config = AppConfig()
    config = app_config.create_conversion_config(
        args.engine,
        voice=default_voice,
        primary_language=primary_language,
    )

    engine_label = args.engine.lower()
    edge_cap = 0
    try:
        edge_cap = int(os.getenv("EDGE_MAX_CONCURRENCY", "") or "0")
    except ValueError:
        edge_cap = 0

    def _snapshot() -> ResourceSnapshot:
        cpu_pct = 0.0
        ram_gb = 0.0
        try:
            cpu_pct = float(psutil.cpu_percent(interval=None))
        except Exception:
            cpu_pct = 0.0
        try:
            mem = psutil.virtual_memory()
            ram_gb = float(mem.available / (1024**3))
        except Exception:
            ram_gb = 0.0
        cpu_idle = max(0.0, 100.0 - cpu_pct)
        return ResourceSnapshot(
            cpu_percent=cpu_pct,
            cpu_idle=cpu_idle,
            ram_gb=ram_gb,
            active_jobs=max(1, int(args.chapter_parallel)),
        )

    tts_factory = TTSFactory()
    engine_pool = JobEnginePool(
        create_engine=tts_factory.create_engine,
        parallel_slots=max(1, int(args.chapter_parallel)),
        edge_cap=edge_cap,
        hardware_profile=hardware_profile,
        stats_provider=_snapshot,
    )
    engine_pool.register_engine(engine_label, config)

    texts: List[str] = []
    for chapter in chapters:
        text = getattr(chapter, "speech_text", None) or chapter.text or ""
        texts.append(text)

    total_chars = sum(len(text) for text in texts)
    if not texts:
        payload = {
            "run_id": args.run_id,
            "engine": engine_label,
            "success": False,
            "engine_available": True,
            "error": "no_chapters",
        }
        print(json.dumps(payload))
        return 1

    output_ext = ".mp3" if engine_label == "edge" else ".wav"

    async def _run() -> Dict[str, object]:
        import asyncio

        init_start = time.perf_counter()
        try:
            async with engine_pool.use(engine_label):
                pass
        except Exception as exc:
            return {"errors": 0, "engine_available": False, "error": str(exc)}
        init_seconds = time.perf_counter() - init_start

        semaphore = asyncio.Semaphore(max(1, int(args.chapter_parallel)))
        errors = 0

        async def synthesize(idx: int, text: str) -> None:
            nonlocal errors
            if not text:
                return
            output_path = output_dir / f"ch{idx:04d}{output_ext}"
            async with semaphore:
                try:
                    async with engine_pool.use(engine_label) as (_, engine_obj):
                        result = await engine_obj.synthesize_async(text, output_path)
                    if result is None:
                        errors += 1
                except Exception:
                    errors += 1

        synth_start = time.perf_counter()
        tasks = [asyncio.create_task(synthesize(idx + 1, text)) for idx, text in enumerate(texts)]
        await asyncio.gather(*tasks)
        synth_seconds = time.perf_counter() - synth_start
        return {
            "errors": errors,
            "engine_available": True,
            "init_seconds": init_seconds,
            "synth_seconds": synth_seconds,
        }

    try:
        import asyncio

        run_outcome = asyncio.run(_run())
    except Exception as exc:
        payload = {
            "run_id": args.run_id,
            "engine": engine_label,
            "success": False,
            "engine_available": False,
            "error": str(exc),
        }
        print(json.dumps(payload))
        return 1
    if run_outcome.get("engine_available") is False:
        payload = {
            "run_id": args.run_id,
            "engine": engine_label,
            "success": False,
            "engine_available": False,
            "error": str(run_outcome.get("error") or "engine_init_failed"),
        }
        print(json.dumps(payload))
        return 1

    init_seconds = float(run_outcome.get("init_seconds") or 0.0)
    synth_seconds = float(run_outcome.get("synth_seconds") or 0.0)

    if not args.keep_audio:
        for path in output_dir.glob(f"*{output_ext}"):
            try:
                path.unlink()
            except OSError:
                pass

    end_ts = time.time()
    payload = {
        "run_id": args.run_id,
        "engine": engine_label,
        "chapter_parallel": int(args.chapter_parallel),
        "edge_enable_parallel": os.getenv("EDGE_ENABLE_PARALLEL"),
        "edge_max_concurrency": os.getenv("EDGE_MAX_CONCURRENCY"),
        "edge_chunk_chars": os.getenv("EDGE_CHUNK_CHARS"),
        "edge_max_segment_seconds": os.getenv("EDGE_MAX_SEGMENT_SECONDS"),
        "coqui_max_workers": os.getenv("COQUI_MAX_WORKERS"),
        "piper_max_procs": os.getenv("PIPER_MAX_PROCS"),
        "network_profile": args.network_profile,
        "voice": config.voice,
        "model_path": str(config.model_path) if config.model_path else None,
        "chapters": len(texts),
        "chars": total_chars,
        "init_seconds": init_seconds,
        "synth_seconds": synth_seconds,
        "total_seconds": (end_ts - start_ts),
        "chars_per_second": (total_chars / synth_seconds) if synth_seconds > 0 else 0.0,
        "errors": int(run_outcome.get("errors", 0)),
        "success": int(run_outcome.get("errors", 0)) == 0,
        "engine_available": True,
        "output_dir": str(output_dir),
    }
    print(json.dumps(payload))
    return 0
