# Wiki: EPUB to MP3

Converta ebooks EPUB/PDF em audiobooks MP3 usando múltiplos motores de TTS, fallback automático, cache por livro, interface web com progresso em tempo real, app SwiftUI para Apple e app Flutter para Linux/Windows/Android.

## Visão geral

Este projeto tem quatro modos principais de uso:

- `CLI`: conversão local via terminal
- `Web`: FastAPI + frontend React
- `Apple` (`ios/EpubToMp3/`): app SwiftUI para macOS / iPadOS / iOS; o macOS embute o sidecar Python
- `Não-Apple` (`flutter_app/`): app Flutter para Linux / Windows / Android

Os modos local CLI e web compartilham os mesmos diretórios persistentes por padrão:

- `.cache/` para texto parseado e artefatos intermediários
- `output/` para MP3s, ZIPs e arquivos finais
- `.jobs/` para metadados do servidor web
- `.uploads/` para uploads da interface web

## Links rápidos

- [Primeiros passos](./Getting-Started.md)
- [Uso via CLI e Web](./CLI-and-Web.md)
- [Desktop, Mobile e Releases](./Desktop-Mobile-and-Releases.md)
- [Arquitetura](./Architecture.md)
- [Configuração e Performance](./Configuration-and-Performance.md)
- [Deploy e Hugging Face Spaces](./Deployment-and-HF-Spaces.md)
- [Troubleshooting](./Troubleshooting.md)
- [Contribuição e Segurança](./Contributing-and-Security.md)

## Recursos principais

- Conversão de `EPUB` e `PDF` para `MP3`
- Cadeia de fallback entre `Edge-TTS`, `Kokoro` e `Piper`
- Preservação da estrutura do sumário e hierarquia de capítulos
- Cache agressivo para evitar reprocessamento de texto
- Reprodução progressiva no frontend conforme os chunks são sintetizados
- Download por capítulo e ZIP completo
- App nativo macOS (SwiftUI) com sidecar Python embutido
- Apps nativos Linux / Windows / Android (Flutter)
- Arquivo iOS / iPadOS sideloadável

## Tecnologias principais

- Backend: `Python`, `FastAPI`
- Frontend: `React`, `TypeScript`, `Vite`
- Cliente Apple: `SwiftUI`
- Cliente não-Apple: `Flutter`
- CI/CD: `GitHub Actions`
- Publicação web/demo: `Hugging Face Spaces`

## Onde começar

Se você vai usar o projeto:

- comece por [Primeiros passos](./Getting-Started.md)

Se você vai desenvolver:

- leia [Arquitetura](./Architecture.md)
- depois [Configuração e Performance](./Configuration-and-Performance.md)
- e [Contribuição e Segurança](./Contributing-and-Security.md)
