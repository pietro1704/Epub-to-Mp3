"""Run the pinned Portuguese ONNX export with a synthetic reference voice."""
import hashlib
import json
import os
from pathlib import Path
import resource
import sys
import time

import numpy as np
import onnxruntime as ort
import soundfile as sf
from pocket_tts_onnx import PocketTTSOnnx


class TwoThreadPocket(PocketTTSOnnx):
    def _make_session_options(self):
        options = ort.SessionOptions()
        options.intra_op_num_threads = 2
        options.inter_op_num_threads = 1
        return options


def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


assets, engine, corpus_path, output = sys.argv[1:]
assets, output = Path(assets), Path(output)
corpora = json.loads(Path(corpus_path).read_text())
name = os.environ["BENCH_CORPUS"]
iteration = int(os.environ["BENCH_ITERATION"])
text = corpora[name]
np.random.seed(42)
emit({"event": "loading", "engine": engine, "pid": os.getpid()})
started = time.perf_counter()
tts = TwoThreadPocket(models_dir=str(assets / "pocket"), language="portuguese",
                      precision="int8", device="cpu", temperature=0.7, lsd_steps=1)
load = time.perf_counter() - started
emit({"event": "loaded", "engine": engine, "load_s": load, "runtime": ort.__version__})
path = output / f"{engine}-{name}-{iteration}.wav"
row = {"engine": engine, "corpus": name, "iteration": iteration,
       "characters": len(text), "model_state": "first_generation",
       "file": str(path), "load_s": load, "first_pcm_callback_s": None,
       "first_non_silent_callback_s": None, "callback_count": 0,
       "reference": str(assets.parent / "reference.wav")}
emit({"event": "start", **row})
started = time.perf_counter()
parts = []
for chunk in tts.stream(text, voice=row["reference"], first_chunk_frames=2, max_chunk_frames=15):
    if not len(chunk):
        continue
    elapsed = time.perf_counter() - started
    row["callback_count"] += 1
    if row["first_pcm_callback_s"] is None:
        row["first_pcm_callback_s"] = elapsed
    if np.max(np.abs(chunk)) > 0.001 and row["first_non_silent_callback_s"] is None:
        row["first_non_silent_callback_s"] = elapsed
        emit({"event": "first_audio", "seconds": elapsed})
    parts.append(chunk)
row["synthesis_s"] = time.perf_counter() - started
samples = np.concatenate(parts)
if not len(samples) or not np.isfinite(samples).all() or np.max(np.abs(samples)) <= 0.001:
    raise ValueError("Missing, nonfinite or silent audio")
sf.write(path, samples, tts.sample_rate, subtype="PCM_16")
row["file_ready_s"] = time.perf_counter() - started
row["audio_s"] = len(samples) / tts.sample_rate
row["sample_rate"] = tts.sample_rate
row["rtf"] = row["file_ready_s"] / row["audio_s"]
row["characters_per_s"] = len(text) / row["file_ready_s"]
row["peak_rss_bytes"] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
row["peak_amplitude"] = float(np.max(np.abs(samples)))
row["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
row["status"] = "generated"
emit({"event": "result", **row})
