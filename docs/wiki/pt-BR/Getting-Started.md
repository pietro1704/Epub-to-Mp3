# Primeiros Passos

## Requisitos

Recomendado:

- `mise`
- `Python 3.11`
- `Node.js`
- `ffmpeg`
- `espeak-ng` para Kokoro

## Instalação recomendada

```bash
git clone https://github.com/pietro1704/Epub-to-Mp3.git
cd Epub-to-Mp3
mise run install
```

Isso prepara:

- ambiente virtual Python
- dependências web
- binário do Piper

## Instalação manual

```bash
pip install -r requirements.txt -r python_app/requirements.txt
```

No macOS:

```bash
brew install ffmpeg espeak-ng
```

No Linux:

```bash
sudo apt-get install -y ffmpeg espeak-ng
```

## Validando a instalação

```bash
mise run test:unit
mise run test:web
```

## Primeiro uso

CLI:

```bash
source .venv/bin/activate
python -m python_app.main convert livro.epub
```

Servidor web:

```bash
mise run web
```

Frontend em desenvolvimento:

```bash
cd web && npm run dev
```

## Downloads prontos

O projeto publica builds em:

- macOS
- Windows
- Linux
- Android
- iOS

Consulte a página de `Releases` do repositório.
