# Arquitetura

## Visão de alto nível

O projeto é dividido em quatro camadas:

1. `python_app/`: backend e pipeline de conversão
2. `web/`: frontend React/TypeScript
3. `ios/EpubToMp3/`: cliente UIKit/AppKit (macOS · iPadOS · iOS) com runtime Python embutido no macOS
4. `flutter_app/`: cliente Flutter (Linux · Windows · Android)

## Dois pipelines de conversão

Existe um detalhe crítico:

- `python_app/src/converter.py`: pipeline da CLI
- `python_app/server.py`: pipeline da Web/API

Eles são separados. Mudanças de comportamento relevantes precisam ser espelhadas nos dois fluxos quando aplicável.

## Backend

Arquivos principais:

- `python_app/main.py`: entrada CLI
- `python_app/server.py`: API FastAPI
- `python_app/src/config.py`: configuração da conversão
- `python_app/src/ebook_reader.py`: parsing de EPUB/PDF
- `python_app/src/cache_manager.py`: cache por livro/capítulo
- `python_app/src/job_manager.py`: persistência e fila de jobs
- `python_app/src/tts/`: motores de TTS

## Frontend

Arquivos principais:

- `web/src/App.tsx`: composição principal da aplicação
- `web/src/hooks/useConversionFlow.ts`: máquina de estado de conversão
- `web/src/services/ConversionService.ts`: cliente HTTP/SSE/polling
- `web/src/i18n/translations.ts`: traduções

## Clientes nativos

- `ios/EpubToMp3/project.yml`: descritor XcodeGen do cliente Apple nativo e do runtime Python embutido
- `flutter_app/lib/`: código do cliente Flutter (Linux · Windows · Android)


## Persistência

Por padrão, o projeto usa:

- `.cache/`
- `output/`
- `.jobs/`
- `.uploads/`

Esses diretórios podem ser alterados por variáveis de ambiente.

## Cadeia de fallback de engines

CLI:

- Edge multilíngue
- Edge monolíngue
- Piper

Web:

- Edge
- Piper

## Fluxo de runtime

1. arquivo é enviado ou lido
2. parser extrai capítulos
3. cache é consultado
4. capítulos são convertidos por TTS
5. chunks podem ser publicados progressivamente
6. arquivos finais são gravados em `output/`
