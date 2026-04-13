# Wiki: EPUB to MP3

Converta ebooks EPUB/PDF em audiobooks MP3 usando múltiplos motores de TTS, fallback automático, cache por livro, interface web com progresso em tempo real e app desktop com Tauri.

## Visão geral

Este projeto tem três modos principais de uso:

- `CLI`: conversão local via terminal
- `Web`: FastAPI + frontend React
- `Desktop`: app Tauri com frontend web e sidecar Python

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
- App desktop empacotado para macOS, Windows e Linux
- Builds mobile distribuídos por CI

## Tecnologias principais

- Backend: `Python`, `FastAPI`
- Frontend: `React`, `TypeScript`, `Vite`
- Desktop: `Tauri`
- CI/CD: `GitHub Actions`
- Publicação web/demo: `Hugging Face Spaces`

## Onde começar

Se você vai usar o projeto:

- comece por [Primeiros passos](./Getting-Started.md)

Se você vai desenvolver:

- leia [Arquitetura](./Architecture.md)
- depois [Configuração e Performance](./Configuration-and-Performance.md)
- e [Contribuição e Segurança](./Contributing-and-Security.md)
