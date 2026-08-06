# Desktop, Mobile e Releases

## Apple (macOS / iPadOS / iOS) — UIKit/AppKit

O cliente oficial Apple está em `ios/EpubToMp3/`. No macOS o app embute
o runtime Python dentro do `.app`; iPadOS e
iOS apontam para um backend remoto.

Build headless do macOS:

```bash
mise run mac:build
# → a tarefa imprime o caminho do .app gerado, normalmente ios/EpubToMp3/.build/Release/EpubToMp3.app
```


Abrir no Xcode:

```bash
cd ios/EpubToMp3
xcodegen generate
open EpubToMp3.xcodeproj
```

## Não-Apple (Linux / Windows / Android) — Flutter

O cliente oficial não-Apple está em `flutter_app/`. Um único codebase Dart,
mesmo contrato FastAPI.

```bash
mise run flutter:build-linux        # Linux desktop release
mise run flutter:build-windows      # Windows desktop release
mise run flutter:build-apk          # Android (release)
```

## Releases

`release-desktop.yml` roda em cada tag `v*.*.*` e publica:

- macOS `.zip` (app Apple nativo com runtime Python embutido)
- Linux `.tar.gz` (Flutter)
- Windows `.zip` (Flutter)
- Android `.apk` (Flutter)
- Imagem Docker (`ghcr.io/<owner>/epub-to-mp3:latest`)
- Arquivo iOS sem assinatura (sideload via AltStore)
