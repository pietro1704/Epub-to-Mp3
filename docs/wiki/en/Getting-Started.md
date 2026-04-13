# Getting Started

## Requirements

Recommended:

- `mise`
- `Python 3.11`
- `Node.js`
- `ffmpeg`
- `espeak-ng` for Kokoro

## Recommended installation

```bash
git clone https://github.com/pietro1704/Epub-to-Mp3.git
cd Epub-to-Mp3
mise run install
```

This prepares:

- the Python virtual environment
- web dependencies
- the Piper binary

## Manual installation

```bash
pip install -r requirements.txt -r python_app/requirements.txt
```

On macOS:

```bash
brew install ffmpeg espeak-ng
```

On Linux:

```bash
sudo apt-get install -y ffmpeg espeak-ng
```

## Validate the setup

```bash
mise run test:unit
mise run test:web
```

## First run

CLI:

```bash
source .venv/bin/activate
python -m python_app.main convert book.epub
```

Web server:

```bash
mise run web
```

Frontend dev server:

```bash
cd web && npm run dev
```
