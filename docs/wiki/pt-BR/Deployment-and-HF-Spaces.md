# Deploy e Hugging Face Spaces

## Modos de deploy

- local CLI
- local web
- demo/publicação em `Hugging Face Spaces`
- releases desktop/mobile via `GitHub Actions`

## Hugging Face Spaces

Entrada:

- `hf_app.py`

Container:

- `Dockerfile`

Porta padrão:

- `7860`

## Paths persistentes no HF

No HF, o projeto usa `/data/epub-to-mp3` como raiz persistente.

Isso preserva:

- cache
- outputs
- jobs

entre reinicializações.

## Variáveis e comportamento no HF

O projeto aplica um perfil mais conservador em:

- concorrência do Edge
- paralelismo por capítulo
- timeouts
- thresholds de slow mode

## Storage permanente

Para armazenamento externo opcional, consulte:

- [docs/R2_SETUP.md](/Users/pietropugliesi/Developer/Epub-to-Mp3/docs/R2_SETUP.md)

## Deploys automatizados

Workflows importantes:

- `CI`
- `CodeQL`
- `Sync to Hugging Face Space`
- `Release Desktop`
- `Auto Release`

## Git e sync

Para detalhes de workflow Git/HF:

- [docs/GIT_WORKFLOW.md](/Users/pietropugliesi/Developer/Epub-to-Mp3/docs/GIT_WORKFLOW.md)
