# Voice Samples

This directory contains voice samples for each TTS engine. These samples help users preview voice quality before converting.

## Directory Structure

```
voice_samples/
├── edge/           # Microsoft Edge-TTS cloud voices
├── coqui/          # Coqui XTTS neural voices
├── kokoro/         # Kokoro lightweight local voices
├── spark/          # Spark-TTS LLM-based voices
└── README.md       # This file
```

## Generating Samples

### Edge-TTS
```bash
# Generate sample with Edge-TTS
edge-tts --voice "pt-BR-ThalitaMultilingualNeural" \
  --text "Olá! Este é um exemplo de voz em português brasileiro." \
  --write-media voice_samples/edge/pt-BR-ThalitaMultilingualNeural.mp3
```

### Kokoro
```python
from kokoro import KPipeline
import soundfile as sf

pipeline = KPipeline(lang_code='a')
text = "Hello! This is a sample of the Kokoro voice."

for gs, ps, audio in pipeline(text, voice='af_heart'):
    sf.write('voice_samples/kokoro/af_heart.wav', audio, 24000)
    break
```

### Spark-TTS
```bash
python -m cli.inference \
    --text "Hello! This is a sample of the Spark voice." \
    --model_dir pretrained_models/Spark-TTS-0.5B \
    --save_dir voice_samples/spark/
```

### Coqui
```python
from TTS.api import TTS

tts = TTS("tts_models/multilingual/multi-dataset/xtts_v2")
tts.tts_to_file(
    text="Olá! Este é um exemplo de voz do Coqui XTTS.",
    file_path="voice_samples/coqui/xtts_v2_pt.wav",
    language="pt"
)
```

## Available Voices

### Edge-TTS (Microsoft Cloud)
- `pt-BR-ThalitaMultilingualNeural` - Portuguese Brazilian (multilingual)
- `pt-BR-FranciscaNeural` - Portuguese Brazilian female
- `en-US-JennyNeural` - English US female
- `es-ES-ElviraNeural` - Spanish female

### Kokoro (Local, 82M params)
- `af_heart` - American English female (default)
- `af_bella` - American English female
- `bf_emma` - British English female
- `jf_alpha` - Japanese female
- `zf_xiaobei` - Chinese female

### Spark-TTS (LLM-based)
- `default` - Default Spark voice
- `clone` - Voice cloning (requires reference audio)

### Coqui XTTS
- `tts_models/multilingual/multi-dataset/xtts_v2` - Multilingual neural voice

## Usage in Web UI

Voice samples can be played from the web UI when selecting a voice. The frontend will look for audio files matching the voice name in the appropriate engine directory.
