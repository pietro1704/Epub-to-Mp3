# Troubleshooting

## The web server does not start

Check:

- Python dependencies
- `ffmpeg`
- local port availability
- backend logs

Useful commands:

```bash
mise run web
uvicorn python_app.server:app --port 8000
```

## Kokoro does not work

Common cause:

- missing `espeak-ng`

## Piper does not work

Check:

- active virtual environment
- available binary/model

## macOS SwiftUI app fails during startup

Check:

- packaged Python sidecar at `EpubToMp3.app/Contents/Resources/epub-to-mp3-server`
- Console.app filtered by `EpubToMp3` for sidecar stderr
- Rerun `mise run sidecar:build && mise run mac:build` to refresh the embed

## CodeQL reports path-injection

This project uses path sanitization and root confinement in several places. If an alert appears:

1. validate the real flow
2. make sanitization more explicit in code when possible
3. only then dismiss as a justified false positive

## Upload fails because of size

Adjust:

```bash
export MAX_UPLOAD_MB=200
export VITE_MAX_UPLOAD_MB=200
```
