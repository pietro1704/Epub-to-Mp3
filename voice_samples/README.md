# Voice Samples

This directory contains optional sample audio for the TTS engines exposed by the application.

## Directory Structure

```text
voice_samples/
├── edge/           # Microsoft Edge-TTS cloud voices
├── piper/          # Piper offline ONNX voices
└── README.md       # This file
```

## Generating samples

### Edge-TTS

```bash
edge-playback --text "Hello! This is an Edge-TTS sample." \
  --voice en-US-JennyNeural \
  --write-media voice_samples/edge/en-US-JennyNeural.mp3
```

### Piper

Use the Piper binary with an installed ONNX model and write the resulting WAV
under `voice_samples/piper/`. The application discovers Piper models from its
configured model directory; samples are not part of the public engine API.

## Voices exposed by the API

The backend's `GET /api/voices` endpoint returns the runtime catalog for
`edge`, `piper`, and `auto`. The catalog is authoritative because Piper entries
depend on installed models.

## Usage in Web UI

Samples are optional and are not required for conversion. The web UI previews
voices through `GET /api/voice-preview` using the same Edge/Piper contract.
