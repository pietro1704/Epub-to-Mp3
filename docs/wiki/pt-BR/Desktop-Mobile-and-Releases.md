# Desktop, Mobile e Releases

## Desktop

O app desktop usa:

- `Tauri` no shell nativo
- frontend React em `web/`
- sidecar Python empacotado para rodar o backend local

## Tarefas principais

Servidor local do desktop:

```bash
mise run desktop:server
```

Build do sidecar:

```bash
mise run desktop:sidecar
```

Build do frontend do desktop:

```bash
mise run desktop:web
```

Build do app desktop:

```bash
mise run desktop:build
```

Dev mode:

```bash
mise run desktop:dev
```

## Mobile

O repositório também gera artefatos mobile via CI.

Build web para mobile:

```bash
mise run mobile:build
```

Os pacotes nativos são gerados nos workflows de release.

## Releases

O pipeline publica:

- nightly a partir da branch principal
- releases versionadas por tag

Artefatos comuns:

- macOS `.dmg`
- Windows `.exe` / `.msi`
- Linux `.flatpak`, `.snap`, `.AppImage`, `.deb`
- Android `.apk`
- iOS `.ipa`

## Observações importantes

- o sidecar Python precisa existir em `desktop/src-tauri/binaries/`
- o app desktop depende da disponibilidade local do backend Python
- o fluxo de restart do sidecar tem cobertura de teste na CI
