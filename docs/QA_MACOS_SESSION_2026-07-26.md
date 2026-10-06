# QA macOS — sessão de continuidade — 2026-07-26

## Objetivo

Validar o estado atual do Epub-to-Mp3 conforme os planos iOS/QA e executar o
que é possível no app nativo macOS, sem iniciar Simulator/CoreSimulator.

## Contexto canônico do projeto

- Plano principal: `docs/plans/ios-first-action-plans.md`, com Plano 0–4.
- Plano de QA complementar: `QA_FIX_PLAN.md`, com U0–U7.
- Backlog técnico consolidado: `APP_REMAINING_WORK.md`, com APP-001–APP-022.
- Não foi encontrada uma lista literal P0–P9 no repositório.
- CLI, web local e app macOS compartilham o backend Python e os diretórios de
  cache/output quando não há override de `PERSISTENT_ROOT`, `CACHE_DIR` ou
  `OUTPUT_DIR`.
- O Mac usado é Intel, com 8 GiB de RAM. Simulator/CoreSimulator não deve ser
  usado neste equipamento por risco de kernel panic.

## Estado da árvore no início/fim da sessão

Branch: `master`, alinhada com `origin/master` antes das alterações locais.

Alterações locais presentes ao final:

- `ios/EpubToMp3/project.yml`
- `ios/EpubToMp3/Vendor/site-packages/python_app/src/ebook_reader.py`
- `python_app/src/converter.py`
- `python_app/tests/test_converter.py`
- `python_app/tests/test_macos_appkit_lifecycle_config.py`

Essas alterações não foram commitadas nem enviadas ao remoto.

## Alterações feitas nesta continuidade

### Controle de retries no cenário de teste

O teste `test_convert_chapters_with_errors` usa um engine que falha
permanentemente no segundo capítulo. O default Edge de até seis tentativas,
com backoff real, fazia a suíte parecer travada por mais de 160 segundos.

Foi adicionado suporte opcional a `config.extra["max_chapter_attempts"]`,
limitado entre 1 e 6. O default de produção continua sendo 6 tentativas
normais ou 4 no deferred safe pass. O teste define o limite como 1, pois seu
objetivo é verificar sucesso parcial, não a política de retry.

Arquivos:

- `python_app/src/converter.py`
- `python_app/tests/test_converter.py`

### Vendor iOS sincronizado

O teste de drift encontrou `ebook_reader.py` canônico diferente da cópia
embutida no iOS. A sincronização foi feita pelo task oficial:

```bash
mise run vendor:python
```

O teste de vendor passou depois da sincronização.

### Runpath e regressão macOS

A alteração local já existente em `project.yml` adiciona os dois layouts de
framework necessários ao executável:

- `@executable_path/Frameworks`
- `@executable_path/../Frameworks`

O teste correspondente está em
`python_app/tests/test_macos_appkit_lifecycle_config.py`.

## Verificações executadas

### Testes focados

- Teste macOS: 2 passaram.
- Sanitização Python: 5 passaram.
- Sanitização web: 2 passaram.
- Vendor drift: 13 passaram.
- Teste de conversão parcial após ajuste: 1 passou em 2,38 s.
- `git diff --check`: passou.

### Suíte oficial

Comando:

```bash
mise run test
```

Resultado final:

- Python unit: 2024 passaram, 2 skipped.
- Python integration: 38 passaram, 1 skipped.
- Web lint: passou sem warnings ESLint.
- Web tests: 142 passaram em 20 arquivos.
- TypeScript e build Vite: passaram.
- Warnings conhecidos: depreciações de `httpx`/Starlette, `datetime.utcnow`,
  `imghdr` e logs de telemetria; nenhuma falha funcional.

## Teste do app macOS nativo

Task executado:

```bash
mise run mac:run
```

Resultado do build:

- Build Debug AppKit: `** BUILD SUCCEEDED **`.
- Artefato: `ios/EpubToMp3/.build/Build/Products/Debug/EpubToMp3.app`.
- Projeto Xcode regenerado por XcodeGen.
- Verificação de widget embutido passou.
- Vendor Python foi encontrado e incorporado.
- O executável macOS foi lançado e permaneceu vivo durante o smoke test.

Evidência visual obtida com `screencapture`:

- Janela macOS visível.
- Tamanho observado: aproximadamente 1000×700.
- Biblioteca carregou o livro persistido “The Lord of the Rings”, com capa,
  título e autor.
- Barra de busca, ordenação, navegação lateral e player inferior foram
  renderizados.
- Acessibilidade expôs uma janela `Epub-to-Mp3`.

Limitações do smoke visual:

- A sessão foi interrompida antes de completar todos os fluxos manuais.
- A árvore de acessibilidade SwiftUI expôs poucos controles semânticos; vários
  elementos visuais não puderam ser acionados de forma determinística por
  AppleScript.
- Não foi executado fluxo físico de iPhone nem Simulator.
- O app Debug local não é assinado; isso é esperado para este build local e
  não representa uma validação de distribuição Release.

## Estado dos itens relevantes do plano

- Plano 0/U0: inventário atualizado; drift do vendor corrigido; alterações
  locais continuam separadas e não commitadas.
- APP-016: sanitização HTML/CSS já presente e coberta nos lados Python/web.
- APP-017: upload incremental já presente e coberto.
- APP-018: limpeza de cache por livro já presente e coberta.
- APP-019: proteção contra polling concorrente/regressivo já presente e
  coberta por testes web.
- APP-001/U1–U4: código e testes locais existem, mas aceite visual/áudio
  completo ainda depende de roteiro físico no iPhone e de validação end-to-end
  de downloads/offline.
- U6: build macOS Debug validado nesta sessão; build Release, assinatura e
  release final continuam gates separados.

## Próximos passos recomendados

1. Reabrir o app macOS com uma sessão limpa e completar manualmente Biblioteca,
   Conversões, Ajustes, abertura do livro e player.
2. Executar conversão real controlada pelo app macOS usando
   `web/public/sample.epub`, verificando MP3 com `ffprobe`.
3. Validar no iPhone físico os fluxos de reader, resume, áudio e offline.
4. Revisar os cinco arquivos modificados, separar commits focados e só então
   fazer commit/push.
5. Após eventual push, monitorar o CI do commit exato.

## Continuidade — fixture offline/download/eviction e gates adicionais

### Fixture integrada controlada

Foi adicionada a regressão:

`ios/EpubToMp3/EpubToMp3Tests/DownloadManagerBackgroundTests.swift`

Teste: `testLocalFixtureDownloadsAllChaptersAndRoutesPlaybackOffline`.

O cenário cria dois MP3s temporários, nos índices EPUB 0 e 4, e usa o loop
público `DownloadManager.enqueueAll` com URLs `file://`. O teste aguarda o estado
`.completed`, verifica:

- `DownloadProgress.completedChapters == 2`;
- manifesto completo;
- arquivos locais presentes nos índices 0 e 4;
- `DownloadManager.localAudioURL` com arquivo não vazio;
- `PlaybackRouter` escolhendo `.audio(localURL)` sem `baseURL`, representando o
  caminho de reprodução sem rede.

Resultado atual: 1/1 passou.

### Testes Swift/macOS focados

O scheme `EpubToMp3Mac` foi compilado com `build-for-testing` com sucesso.
Depois, o bundle foi executado diretamente via `xcrun xctest` no host macOS.
As seis suítes focadas passaram:

- `DownloadManagerHelperTests`: 8;
- `ResumeStoreTests`: 4;
- `DownloadManagerResumeTests`: 1;
- `DownloadManagerBackgroundTests`: 9;
- `PlaybackRouterTests`: 11;
- `AudiobookCacheEvictionTests`: 15.

Total: 48 testes, 0 falhas.

Para a execução direta, foi necessário reproduzir no derived data ignorado o
layout de host que o Xcode injeta durante `test`, disponibilizando o
`EpubToMp3.debug.dylib` e o `Python.framework` sob o bundle XCTest. Isso é uma
peculiaridade do runner direto, não uma alteração no código-fonte.

### Build genérico iOS

Comando executado sem Simulator/CoreSimulator:

```text
mise exec -- xcodebuild -project ios/EpubToMp3/EpubToMp3.xcodeproj -scheme EpubToMp3 -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath ios/EpubToMp3/.build-ios CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- build
```

Resultado: `** BUILD SUCCEEDED **`.

Artefatos verificados no build:

- `EpubToMp3.app` arm64;
- `EpubToMp3Widget.appex` independente;
- `EpubToMp3ShareExtension.appex` independente;
- ambos embutidos em `EpubToMp3.app/PlugIns/`.

Esse gate confirma packaging/compilação genérica. Não confirma instalação,
áudio, gestos ou offline no iPhone físico.

### Suíte geral e bloqueio atual

`mise run test` foi repetido:

- 2033 passaram;
- 2 skipped;
- 38 deselected;
- 348 warnings conhecidos;
- 1 falha: `TestCollectFootnotesPerformance.test_large_anchor_count_completes_quickly`, 14,35 s contra limite de 6,5 s.

A repetição isolada do mesmo teste passou em 5,93 s. O resultado atual é,
portanto, uma instabilidade de performance reproduzida na suíte completa, não
um gate verde; a causa ainda precisa ser isolada.

### Matriz atual contra U0–U7

- U0: inventário da árvore local concluído sem descartar alterações.
- U1/U2: Reader/toolbar macOS validado visualmente; aceite UIKit/iPhone e
  interações físicas continuam pendentes.
- U3: contratos de resume, duração/roteamento e ciclo de vida cobertos nos
  testes focados; cenário físico Livro A → B → A ainda pendente.
- U4: fixture local integrada e eviction/resume/rota validados no macOS; rede
  desabilitada em device e HTTP real continuam pendentes.
- U5: reclassificação dos bugs históricos continua pendente de reprodução nos
  dispositivos afetados.
- U6: Release macOS assinado, Debug macOS e build genérico iOS com appex
  passaram; iPhone físico, Release iOS e aceite de runtime continuam pendentes.
- U7: não necessário nesta etapa; não há evidência para abrir migração UIKit
  integral.

## Artefatos temporários

Os derived data temporários `.build-ios` e `.build-tests` usados nesta
continuidade foram removidos após a verificação. O artefato Release existente
em `.build/Release` e os artefatos de vendor/build persistentes foram
preservados; não houve limpeza ampla nem alteração de dados do usuário.
