# Deployment and Hugging Face Spaces

## Deployment modes

- local CLI
- local web
- public/demo deployment on `Hugging Face Spaces`
- desktop/mobile releases via `GitHub Actions`

## Hugging Face Spaces

Entry point:

- `hf_app.py`

Container:

- `Dockerfile`

Default port:

- `7860`

## Persistent paths on HF

On Hugging Face, the project uses `/data/epub-to-mp3` as the persistent root.

That preserves:

- cache
- outputs
- jobs

across restarts.

## Optional permanent storage

For external object storage, see:

- [docs/R2_SETUP.md](/Users/pietropugliesi/Developer/Epub-to-Mp3/docs/R2_SETUP.md)

## Automated workflows

Key workflows:

- `CI`
- `CodeQL`
- `Sync to Hugging Face Space`
- `Release Desktop`
- `Auto Release`
