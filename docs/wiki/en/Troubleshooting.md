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

## Desktop app fails during startup

Check:

- packaged Python sidecar in `desktop/src-tauri/binaries/`
- Tauri logs
- automatic sidecar restart flow

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
