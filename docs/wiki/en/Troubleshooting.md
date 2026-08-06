# Troubleshooting

## The web server does not start

Check:

- Python dependencies
- `ffmpeg`
- local port availability
- backend logs

Useful commands:

```bash
mise run dev
uvicorn python_app.server:app --port 8000
```


## Piper does not work

Check:

- active virtual environment
- available binary/model

## macOS native app fails during startup

Check:

- the bundled Python runtime and app resources
- Console.app filtered by `EpubToMp3` for embedded-server stderr
- rerun `mise run mac:build` to refresh the app bundle

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
