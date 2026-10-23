"""Isolated research client, not an application runtime or sidecar."""

import argparse
import asyncio
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import subprocess
import threading
import time

import aiohttp
import edge_tts
from edge_tts.communicate import DRM


async def measure(args, communicate_factory=None):
    text = args.text_file.read_text(encoding="utf-8")
    if not 1 <= len(text) <= 500:
        raise ValueError("Use the reviewed 1..500-character corpus")
    output = args.output
    timing = Path(str(output) + ".timing.json")
    pcm = Path(str(output) + ".decoded.pcm")
    errors = Path(str(output) + ".decode.stderr")
    if any(p.exists() for p in (output, timing, pcm, errors)):
        raise ValueError("Never overwrite an earlier attempt")
    started = time.monotonic()
    report = {
        "provider": "Edge Read Aloud", "voice": args.voice,
        "model_revision": "not exposed", "server_cache": "unknown",
        "connection": "fresh", "client_version": importlib.metadata.version("edge-tts"),
        "probe_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "text_sha256": hashlib.sha256(text.encode()).hexdigest(),
        "request_start_monotonic_s": started, "status": "started",
        "decoder": "ffmpeg MP3 -> PCM16 mono 24000Hz; explicit format, probesize32/analyzeduration0",
        "first_signal_threshold": "absolute PCM16 sample >32; not actual speaker output",
        "retry_policy": "stop first 403/429; DRM clock-adjustment retry disabled",
    }
    original_handler = DRM.handle_client_response_error

    def stop_first_refusal(error):
        report["http_status"] = error.status
        report["stopped_first_403"] = True
        raise error

    DRM.handle_client_response_error = staticmethod(stop_first_refusal)
    process = None
    reader = None
    return_code = 0
    decoder_errors = None
    decoded = None
    try:
        decoder_errors = errors.open("xb")
        decoded = pcm.open("xb")
        process = subprocess.Popen(
            ["ffmpeg", "-nostdin", "-v", "error", "-f", "mp3", "-probesize", "32",
             "-analyzeduration", "0", "-i", "pipe:0", "-f", "s16le", "-ac", "1",
             "-ar", "24000", "pipe:1"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=decoder_errors,
        )

        def receive_pcm():
            pending = b""
            count = 0
            while True:
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    break
                arrived = time.monotonic() - started
                report.setdefault("first_pcm_request_s", arrived)
                decoded.write(chunk)
                count += len(chunk)
                pending += chunk
                complete = len(pending) // 2 * 2
                values = memoryview(pending[:complete]).cast("h")
                if any(abs(value) > 32 for value in values):
                    report.setdefault("first_non_silent_pcm_request_s", arrived)
                del values
                pending = pending[complete:]
            report["decoded_pcm_bytes"] = count
            report["audio_duration_s"] = count / 48000
            report["partial_pcm_frame"] = bool(pending)

        reader = threading.Thread(target=receive_pcm, daemon=True)
        reader.start()
        communicate = (communicate_factory or edge_tts.Communicate)(text, args.voice, connect_timeout=15, receive_timeout=30)
        with output.open("xb") as audio:
            async with asyncio.timeout(args.timeout):
                async for event in communicate.stream():
                    if event["type"] == "audio":
                        arrived = time.monotonic() - started
                        report.setdefault("first_encoded_audio_request_s", arrived)
                        audio.write(event["data"])
                        process.stdin.write(event["data"])
                        process.stdin.flush()
                        report["last_encoded_audio_request_s"] = arrived
            audio.flush()
            os.fsync(audio.fileno())
            report["complete_mp3_persisted_s"] = time.monotonic() - started
        process.stdin.close()
        process.wait(timeout=15)
        reader.join(timeout=10)
        if reader.is_alive() or process.returncode != 0 or not report.get("first_non_silent_pcm_request_s") or report.get("partial_pcm_frame"):
            raise RuntimeError("The complete non-silent MP3 was not successfully decoded")
        decoded.flush()
        os.fsync(decoded.fileno())
        report["audio_sha256"] = hashlib.sha256(output.read_bytes()).hexdigest()
        report["status"] = "received_non_silent_pcm"
    except aiohttp.ClientResponseError as error:
        report["http_status"] = error.status
        report["response_headers"] = {k: v for k, v in (error.headers or {}).items()
                                      if k.lower() in {"retry-after", "ratelimit", "ratelimit-policy"}}
        report["status"] = "provider_limit_or_refusal" if error.status in (403, 429) else "http_error"
        report["error"] = str(error.status)
        return_code = 1
    except (TimeoutError, asyncio.TimeoutError, subprocess.TimeoutExpired) as error:
        report.update(status="timeout", error=str(error))
        return_code = 124
    except (asyncio.CancelledError, KeyboardInterrupt):
        report["status"] = "cancelled"
        return_code = 130
    except Exception as error:
        report.update(status="failed", error=f"{type(error).__name__}: {error}")
        return_code = 1
    finally:
        DRM.handle_client_response_error = staticmethod(original_handler)
        if process is not None:
            if process.stdin and not process.stdin.closed:
                process.stdin.close()
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            if reader is not None:
                reader.join(timeout=2)
            if process.stdout:
                process.stdout.close()
        if decoded is not None:
            decoded.close()
        if decoder_errors is not None:
            decoder_errors.close()
        report["client_total_s"] = time.monotonic() - started
        partial = Path(str(timing) + ".partial")
        partial.write_text(json.dumps(report, indent=2) + "\n")
        partial.replace(timing)
    print(json.dumps(report))
    return return_code


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--voice", choices=["pt-BR-FranciscaNeural", "en-US-GuyNeural"], required=True)
    parser.add_argument("--text-file", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=90)
    raise SystemExit(asyncio.run(measure(parser.parse_args())))
