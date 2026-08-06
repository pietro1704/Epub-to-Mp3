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

Armazenamento externo de objetos não é configurado por este repositório. A
documentação de deploy deve usar apenas links relativos ao repositório.

## Deploys automatizados

Workflows importantes:

- `CI`
- `CodeQL`
- `Sync to Hugging Face Space`
- `Release Desktop`
- `Auto Release`
