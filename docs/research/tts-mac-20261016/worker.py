"""Isolated CPU inference measurement; no production app dependency."""

import hashlib
import json
import os
from pathlib import Path
import resource
import sys
import time

import numpy as np
import sherpa_onnx as s
import soundfile as sf


def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


assets, engine, corpus_path, output = sys.argv[1:]
assets, output = Path(assets), Path(output)
corpora = json.loads(Path(corpus_path).read_text())
directories = {
    "edresson": "vits-piper-pt_BR-edresson-low",
    "faber": "vits-piper-pt_BR-faber-medium",
    "kokoro": "kokoro-int8-multi-lang-v1_0",
    "supertonic": "sherpa-onnx-supertonic-3-tts-int8-2026-05-11",
}
root = assets / directories[engine]
model = s.OfflineTtsModelConfig()
model.num_threads = 2
model.provider = "cpu"
if engine in ("edresson", "faber"):
    model.vits = s.OfflineTtsVitsModelConfig(
        model=str(next(root.glob("*.onnx"))),
        tokens=str(root / "tokens.txt"), data_dir=str(root / "espeak-ng-data"))
elif engine == "kokoro":
    model.kokoro = s.OfflineTtsKokoroModelConfig(
        model=str(root / "model.int8.onnx"), voices=str(root / "voices.bin"),
        tokens=str(root / "tokens.txt"), data_dir=str(root / "espeak-ng-data"),
        lang="pt-br")
else:
    model.supertonic = s.OfflineTtsSupertonicModelConfig(
        duration_predictor=str(root / "duration_predictor.int8.onnx"),
        text_encoder=str(root / "text_encoder.int8.onnx"),
        vector_estimator=str(root / "vector_estimator.int8.onnx"),
        vocoder=str(root / "vocoder.int8.onnx"), tts_json=str(root / "tts.json"),
        unicode_indexer=str(root / "unicode_indexer.bin"), voice_style=str(root / "voice.bin"))
config = s.OfflineTtsConfig(model=model, max_num_sentences=1)
if not config.validate():
    raise ValueError("Invalid native model configuration")
emit({"event": "loading", "engine": engine, "pid": os.getpid()})
started = time.perf_counter()
tts = s.OfflineTts(config)
load = time.perf_counter() - started
emit({"event": "loaded", "engine": engine, "load_s": load, "runtime": s.__version__})
# Interleave short/paragraph to avoid attributing all first-use cost to one text.
for iteration in range(1, 4):
    for name, text in corpora.items():
        if os.environ.get("BENCH_CORPUS", name) != name or int(os.environ.get("BENCH_ITERATION", iteration)) != iteration:
            continue
        path = output / f"{engine}-{name}-{iteration}.wav"
        row = {"engine": engine, "corpus": name, "iteration": iteration,
               "characters": len(text), "model_state": "first_generation" if os.environ.get("BENCH_CORPUS") or (iteration == 1 and name == "short") else "resident",
               "file": str(path), "load_s": load, "first_pcm_callback_s": None,
               "first_non_silent_callback_s": None, "callback_count": 0}
        emit({"event": "start", **row})
        started = time.perf_counter()

        def callback(samples, progress):
            elapsed = time.perf_counter() - started
            row["callback_count"] += 1
            if len(samples):
                if row["first_pcm_callback_s"] is None:
                    row["first_pcm_callback_s"] = elapsed
                if np.max(np.abs(samples)) > 0.001 and row["first_non_silent_callback_s"] is None:
                    row["first_non_silent_callback_s"] = elapsed
                    emit({"event": "first_audio", "seconds": elapsed})
            return 1

        generation = s.GenerationConfig()
        generation.sid = 42 if engine == "kokoro" else 0
        generation.speed = 1.0
        if engine == "supertonic":
            generation.num_steps = 8
            generation.extra = {"lang": "pt"}
        audio = tts.generate(text, generation, callback)
        row["synthesis_s"] = time.perf_counter() - started
        samples = np.asarray(audio.samples, dtype=np.float32)
        if not len(samples) or not np.isfinite(samples).all() or np.max(np.abs(samples)) <= 0.001:
            raise ValueError("Missing, nonfinite or silent generated audio")
        sf.write(path, samples, audio.sample_rate, subtype="PCM_16")
        row["file_ready_s"] = time.perf_counter() - started
        row["audio_s"] = len(samples) / audio.sample_rate
        row["sample_rate"] = audio.sample_rate
        row["rtf"] = row["file_ready_s"] / row["audio_s"]
        row["characters_per_s"] = len(text) / row["file_ready_s"]
        row["peak_rss_bytes"] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        row["peak_amplitude"] = float(np.max(np.abs(samples)))
        row["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        row["status"] = "generated"
        emit({"event": "result", **row})
