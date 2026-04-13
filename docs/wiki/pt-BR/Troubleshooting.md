# Troubleshooting

## O servidor web não sobe

Verifique:

- dependências Python instaladas
- `ffmpeg` presente
- porta local disponível
- logs do backend

Comandos úteis:

```bash
mise run web
uvicorn python_app.server:app --port 8000
```

## Kokoro não funciona

Causa comum:

- `espeak-ng` ausente

## Piper não funciona

Verifique:

- ambiente virtual ativo
- binário/modelo disponível

## App desktop falha no startup

Verifique:

- sidecar Python empacotado em `desktop/src-tauri/binaries/`
- logs do Tauri
- restart automático do sidecar

## CodeQL acusa path-injection

Esse projeto usa sanitização e confinamento por raiz em vários pontos. Se surgir alerta:

1. valide o fluxo real
2. tente deixar a sanitização mais explícita no código
3. só então faça dismiss justificado, se for falso positivo

## Hugging Face não atualiza

Verifique:

- workflow de sync
- logs do Space
- factory reboot

## Upload falha por tamanho

Ajuste:

```bash
export MAX_UPLOAD_MB=200
export VITE_MAX_UPLOAD_MB=200
```

## Testes úteis

```bash
mise run test
mise run test:unit
mise run test:web
mise run test:desktop
```
