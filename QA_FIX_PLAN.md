# EpubToMp3 — plano de QA e correção

Data: 2026-07-22 21:56 -03:00
Status: plano vivo; correções e infraestrutura UIKit/SwiftUI locais até 2026-07-23 08:50 -03:00; a continuidade macOS de 2026-07-26 validou build Release/Debug, smoke visual, fixture local de download/offline/eviction e build genérico iOS, mas o aceite funcional completo ainda está pendente. Evidências: [QA_MACOS_SESSION_2026-07-26.md](docs/QA_MACOS_SESSION_2026-07-26.md).

## Objetivo

Exercitar o app Apple/SwiftUI no macOS deste Mac, além do backend e da web UI, usando automação local e arquivos EPUB/PDF já presentes em `~/Downloads`. Validar telas, navegação, importação, leitura, conversão, áudio, downloads, configurações e estados de erro. Cada correção deve ter teste de regressão e verificação live depois da mudança.

## Escopo e evidências disponíveis

- App nativo macOS: `ios/EpubToMp3/`.
- Backend Python/FastAPI: `python_app/`.
- Web UI React: `web/`.
- Inputs locais: 27 EPUBs e 30 PDFs em `/Users/pietropugliesi/Downloads`; nenhum MP3 foi encontrado.
- Biblioteca persistida do app já contém um EPUB do Hobbit, com bookmark para um arquivo em Downloads.
- Fixtures de texto já existentes: `Documents/Audiobooks/j-ok/fulltext.json` e `j-watch/fulltext.json`.
- Não iniciar o iOS Simulator neste Mac Intel com 8 GiB; a validação Apple deste ciclo será macOS nativo. UI tests iOS ficam como cobertura existente, não como evidência de execução local neste ciclo.

## Baseline já executado

- `mise run test`: terminou com exit 0. Python: 28 passed, 1 skipped, 1851 deselected, 1 warning de depreciação do Starlette/httpx. Web: 20 test files, 142 tests passed; TypeScript/build Vite concluídos.
- `mise run mac:build` em PATH normal: falhou no PyInstaller porque o subprocesso tentou `arch -x86_64` e encontrou `/Users/pietropugliesi/bin/arch`, wrapper de `arch-home`, que não aceita essa flag.
- Repetição com `/usr/bin:/bin:/usr/sbin:/sbin` à frente do PATH: sidecar e app macOS construíram com sucesso. Artefato: `ios/EpubToMp3/.build/Release/EpubToMp3.app`; sidecar embutido em `Contents/Resources/epub-to-mp3-server`.
- Conversão real do fixture `web/public/sample.epub`: 3/3 capítulos, validação 100%, MP3s não silenciosos e `ffprobe` confirmou MP3 mono/24 kHz com durações 10.724 s, 11.132 s e 28.484 s.
- O app lançado permanece vivo e o bootstrap AppKit registra uma janela de 1100x760, mas o WindowServer deste ambiente expõe somente uma janela de aproximadamente 122x133 px; `System Events` reporta 0 janelas.
- O display principal está online, porém inativo: `CGDisplayIsOnline=1`, `CGDisplayIsActive=0`; `screencapture` falha para display e janela. Isso impede atribuir o tamanho observado exclusivamente ao app e bloqueia a QA visual live.

## Estado atual da mudança para UIKit

### O que já está em UIKit

| Superfície | Implementação atual | Estado real |
|---|---|---|
| EPUB paginado/page-curl | `TextKitPageView.swift`: `UIViewControllerRepresentable` → `UIPageViewController` + `TextKitPageController` + `UITextView` | Implementado em código; precisa aceite físico de gestos, safe area, links, seleção, imagens e crossing |
| EPUB scrolling | `AttributedPageView.swift`: `UIViewRepresentable` → `UITextView` nativo no iOS | Implementado em código; precisa verificar paridade com page-curl e ausência de relayout/flicker |
| PDF | `PdfReaderView.swift`: `UIViewRepresentable` → `PDFView` no iOS | Implementado em código; falta validar paginação, toque e retomada no device |
| Share Extension | `ShareViewController.swift` + `SharedContainerInbox.swift` | Implementado em código; target/artefato ainda precisam do gate genérico de iOS e do Share Sheet real |
| Transporte de alta frequência | `PlaybackClock.swift` isolado de `AudioPlayer` e injetado no ambiente | Seam implementado e testado; ainda falta provar que não sobraram leituras quentes nos pais do reader |

### O que continua em SwiftUI/AppKit

- Shell, navegação, biblioteca, settings, conversão, jobs, sheets e composição das telas continuam em SwiftUI.
- `AudioPlayer` continua sendo o serviço AVFoundation e não deve ser reescrito como tela UIKit.
- O macOS continua com SwiftUI + bootstrap AppKit; UIKit não é uma solução para o bloqueio do WindowServer/display inativo.

### Decisão arquitetural para esta fase

O alvo recomendado é **arquitetura híbrida**, não uma reescrita integral do app:

1. UIKit/TextKit/PDFKit fica responsável pelo reader e pelas interações de alta frequência/documento.
2. SwiftUI permanece como shell, navegação, biblioteca, settings e composição de player.
3. Serviços (`AudioPlayer`, `ReaderCoordinator`, `DownloadManager`, cache e modelos) permanecem compartilhados e independentes da camada visual.
4. Uma migração integral para `UIViewController` só deve ser aberta como fase separada se a validação física demonstrar que os bugs restantes vêm do shell SwiftUI. A existência de `UIViewRepresentable` no reader, por si só, não justifica reescrever a biblioteca inteira.

### Itens antigos que já têm implementação e não devem ser reabertos sem reprodução

- `TextKitPageController` já configura `UITextViewDelegate`, links e `UILongPressGestureRecognizer`; `TextKitLinkInteractionTests` cobre o contrato.
- O retreat/page-crossing já possui guards, `Int.max`/last-page seed e testes de regressão; falta aceite físico atualizado.
- `PlaybackClock` e os scrubbers separados já existem; falta auditar leituras residuais e comportamento real.
- `DownloadManager` já tem merge idempotente de manifestos, sessão de background e instalação atômica de arquivos; `ResumeStoreTests`, `DownloadManagerBackgroundTests` e `PlaybackRouterTests` cobrem partes puras.
- O prefetch automático no `InstantReaderView` foi removido e há teste garantindo que abrir/trocar capítulo não baixa áudio silenciosamente.
- A resolução de imagens no fallback EPUB e o isolamento de `PERSISTENT_ROOT` já foram corrigidos neste ciclo; a etapa restante é validação end-to-end, não reaplicar os patches antigos.

## Plano restante — UIKit + correções de bugs

Cada fase abaixo deve seguir: reprodução/diagnóstico → teste de regressão → patch mínimo → teste focado → build → validação na plataforma afetada. Não marcar `RESOLVIDO` por source-scan ou compilação isolada quando o aceite é visual, áudio ou runtime.

### U0 — Fechar o inventário da árvore local

**Objetivo:** separar o trabalho UIKit/reader das correções de infraestrutura já presentes sem apagar alterações locais.

**Arquivos e evidências:** `git status`, `git diff`, `QA_FIX_PLAN.md`, `ios/EpubToMp3/project.yml`, testes Swift novos e modificados.

**Passos:**

1. Classificar cada arquivo modificado como janela macOS, UIKit reader, player/clock, importação/cache, extensão, backend ou teste.
2. Confirmar que cada mudança de código tem teste correspondente.
3. Regenerar o projeto somente quando necessário, a partir de `ios/EpubToMp3/`: `mise exec -- xcodegen generate`.
4. Rodar `git diff --check`; não fazer `reset`, `checkout`, `merge`, commit ou push nesta fase sem autorização explícita.

**Saída:** working tree compreensível e backlog sem duplicar bugs históricos já corrigidos.

### U1 — Fechar a camada UIKit do reader

**Objetivo:** garantir que page-curl, scrolling e PDF tenham superfícies nativas estáveis, mantendo SwiftUI apenas como host/composição.

**Arquivos:**

- `ios/EpubToMp3/EpubToMp3/Views/TextKitPageView.swift`
- `ios/EpubToMp3/EpubToMp3/Views/AttributedPageView.swift`
- `ios/EpubToMp3/EpubToMp3/Views/PdfReaderView.swift`
- `ios/EpubToMp3/EpubToMp3/Views/ReaderView.swift`
- `ios/EpubToMp3/EpubToMp3/Views/ReaderLayoutMath.swift`

**Testes:** `TextKitLinkInteractionTests`, `ReaderTapRoutingTests`, `ReaderChapterAdvanceTests`, `ReaderChromeAutoHideTests`, `ReaderRenderCacheTests`, testes de layout e XCUITests do reader.

**Verificar:**

- nenhum overlay SwiftUI compete com o pan/link/long-press do `UITextView`;
- um toque em link tem precedência sobre chrome/page-turn;
- um toque simples produz uma única ação;
- page-curl não reusa texto antigo após mudança de capítulo ou repaginação;
- texto não some depois que o `UIPageViewController` termina o curl;
- scrolling mantém offset, não prende o primeiro toque e não cria relayout em cada tick;
- PDF preserva layout original e não recebe controles de tipografia EPUB.

**Aceite:** testes focados passam e os fluxos acima são observados no iPhone físico; macOS host tests servem apenas como evidência de contrato.

### U2 — Fechar interação e paridade de produto

**Objetivo:** validar os bugs de UX que dependem da interação real, sem reaplicar patches antigos às cegas.

**Arquivos:** `ReaderView.swift`, `InstantReaderView.swift`, `PlayerReaderView.swift`, `TextKitPageView.swift`, `AttributedPageView.swift`, `EpubHtmlRenderer.swift`, `EpubFallbackParser.swift`.

**Fluxos obrigatórios:**

1. long-press em frase → “Tocar daqui” → início na frase correta;
2. cancelamento do menu sem alterar áudio/posição;
3. crossing para frente e para trás, aterrissando na página correta;
4. links internos/externos e imagens relativas/SVG em EPUB real;
5. chrome oculto/restaurado, safe area, rotação/iPad e Dynamic Type;
6. busca, TOC, bookmarks e seleção explícita sem o player sobrescrever a seleção durante o cooldown.

**Aceite:** cada falha reproduzível ganha teste nominal e correção isolada; “BUG 1–8” do `BUG_SPRINT.md` só muda de status após reprodução atual.

### U3 — Fechar estado, ciclo de vida e áudio quente

**Objetivo:** eliminar desincronização causada por publishers de alta frequência, tasks assíncronas antigas ou duração ainda desconhecida.

**Arquivos:** `PlaybackClock.swift`, `AudioPlayer.swift`, `FullPlayerSheet.swift`, `InstantReaderScrubber.swift`, `PlayerReaderScrubber.swift`, `ReaderCoordinator.swift`, `InstantReaderView.swift`, `PlayerReaderView.swift`.

**Passos:**

1. Buscar leituras residuais de `positionSeconds`, `durationSeconds` e `sleepTimerRemaining` nos pais do reader; somente scrubbers/transportes devem observar o clock.
2. Confirmar KVO/observers de duração para assets locais, streams remotos e segmentos; duração inválida não pode deixar o slider preso em `0...1`.
3. Auditar cancelamento e identidade de `fulltextTask`, `streamTask`, `coverFetchTask`, `downloadTask`, `positionTask` e `sentenceTask` em troca rápida Livro A → Livro B → Livro A.
4. Confirmar que resume pausado, resume tocando e retomada antes do primeiro segmento não perdem capítulo/posição.
5. Revalidar todos os caminhos contra o eixo EPUB 0-based versus índice compacto de capítulos reproduzíveis.

**Testes:** `PlaybackClockTests`, `AudioPlayerUXTests`, `AudioPlayerChapterReconcileTests`, `AudioPlayerDivergenceTests`, `ResumeStoreTests`, `BookOpenViewPriorityTests` e novos testes de cancelamento/asset stale quando a reprodução encontrar uma falha.

### U4 — Fechar offline, downloads e eviction end-to-end

**Objetivo:** provar que o que a UI chama de baixado é realmente reproduzível sem rede e não é removido durante uso.

**Arquivos:** `DownloadManager.swift`, `PlaybackRouter.swift`, `AudioPlayer.swift`, `PlayerReaderView.swift`, `BookOpenView.swift`, `AudiobookCacheEviction.swift`, `LibraryStore.swift`.

**Estado conhecido:** merge de manifestos, download em background, arquivo parcial e rota local já têm implementação/testes unitários. O que falta é a prova integrada.

**Evidência adicional em 2026-07-26:** o teste `DownloadManagerBackgroundTests.testLocalFixtureDownloadsAllChaptersAndRoutesPlaybackOffline` executa o loop público com dois arquivos `file://` temporários, aguarda `.completed`, verifica manifest/arquivos locais nos índices 0 e 4 e confirma que o `PlaybackRouter` escolhe o MP3 local sem URL base. Isso valida a integração local controlada; não substitui o roteiro em device com rede desabilitada nem um download HTTP real.

**Verificar:**

- download completo → modo avião → player escolhe MP3 local validado;
- download seletivo do capítulo 1 e depois do 5 preserva os dois no manifesto;
- arquivo parcial/corrompido não recebe badge de offline nem substitui arquivo válido;
- cancelamento e suspensão não deixam task/manifesto enganoso;
- livro em leitura, síntese ou download ativo não é removido por TTL/orçamento;
- eviction reconcilia `cachedOffline` da biblioteca quando o arquivo desaparece.

**Aceite:** testes unitários e um roteiro de device com rede desabilitada; se o servidor local for necessário, usar fixture controlada e registrar o endpoint/artefato, sem afirmar offline por inspeção do manifest.

**Estado atual:** fixture controlada no macOS passou; o roteiro de device/rede desabilitada continua pendente.

### U5 — Reclassificar bugs históricos em vez de duplicá-los

| Item histórico | Estado para esta fase | Próxima ação |
|---|---|---|
| Retreat na última página | Código/testes presentes; aceite físico pendente | Reproduzir no iPhone e só corrigir se falhar |
| Duração curta no scrubber | Observer/KVO presente no `AudioPlayer`; cobertura real de asset/stream pendente | Testar MP3 local, URL remota e segmento |
| Título certo, início errado | Guards de bootstrap/resume presentes; cold start físico pendente | Abrir, pausar, matar/reabrir e retomar |
| Link no page-curl | Delegate e testes presentes | Validar link interno/externo no device |
| Imagem EPUB | fallback de caminho corrigido e fixtures presentes | Validar EPUB real, SVG e recurso ausente |
| Download automático | Removido do `InstantReaderView` e coberto por teste | Confirmar que nenhum outro call site dispara download implícito |
| Long-press/Tocar daqui | recognizers e plumbing presentes; aceite de interação pendente | Validar frase, offset, menu e cancelamento |

### U6 — Packaging e validação de plataforma

**Objetivo:** separar “código UIKit existe”, “target compila”, “appex está embutido” e “runtime funciona”.

**Gates:**

1. Host macOS: testes Swift focados em lotes independentes; não usar execução monolítica que excede 600 s sem evidência.
2. iOS genérico, sem Simulator: `mise exec -- xcodebuild -project ios/EpubToMp3/EpubToMp3.xcodeproj -scheme EpubToMp3 -destination 'generic/platform=iOS' -derivedDataPath ios/EpubToMp3/.build-ios build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`.
3. Inspecionar `EpubToMp3.app/PlugIns/EpubToMp3ShareExtension.appex` e o `.appex` independente.
4. iPhone físico: build Debug assinado, install, launch e roteiro do reader/player/download.
5. macOS: `mise run mac:build` com PATH normal; depois repetir QA visual apenas com display ativo.
6. Final: `mise run test`, artefatos, processos filhos e `git status`.

**Restrição:** não iniciar Simulator/CoreSimulator neste Mac Intel com 8 GiB. Build genérico e host tests não substituem validação visual/áudio no iPhone.

**Evidência adicional em 2026-07-26:** `xcodebuild` para `generic/platform=iOS` passou sem assinatura, gerando `EpubToMp3.app`, `EpubToMp3Widget.appex` e `EpubToMp3ShareExtension.appex`, com ambos os appex também embutidos em `EpubToMp3.app/PlugIns/`. Isso é gate de packaging, não aceite de runtime no iPhone.

### U7 — Decisão posterior: UIKit integral

Só abrir esta fase se U1–U6 demonstrarem que o shell SwiftUI ainda causa regressões que não podem ser isoladas no reader. Ela incluiria `AppDelegate`/`SceneDelegate`, navegação UIKit, `UIViewController` para biblioteca/settings/conversão/player e uma matriz própria de migração/rollback. Não misturar essa reescrita com correções de bugs do reader.

## Defeitos confirmados / hipóteses a verificar

### P0 ambiental — display macOS inativo bloqueia automação visual

Evidência: após build limpo e lançamento direto do binário com `-ApplePersistenceIgnoreState YES`, o processo permaneceu vivo. O AppKit bootstrap confirmou internamente frame de 1100x760; porém Accessibility reportou 0 janelas, CoreGraphics encontrou somente 122x133 px e `screencapture` retornou `could not create image from display 69734272`. `CGDisplayIsActive` retornou `0`.

Mitigação implementada no app:

1. `WindowGroup` macOS recebe conteúdo com mínimo de 1000x700 e padrão de 1100x760.
2. Bootstrap AppKit faz tentativas tardias até 3 s, aplica frame mínimo e ativa a janela.
3. `AppWindowConfigurationTests` cobre tamanhos e janela de tentativas.

Status: código/teste/build validados; aceite live não pode ser concluído neste Mac enquanto `CGDisplayIsActive=0`. Reexecutar esta etapa com uma sessão gráfica ativa antes de considerar a QA visual concluída.

### P1 — `mise run mac:build` depende de PATH externo

Evidência: o build falhou no ambiente normal por colisão com o wrapper pessoal `~/bin/arch`; o mesmo build passou quando diretórios de sistema foram priorizados.

Plano de correção:

1. Tornar a task de build hermética quanto ao binário universal `arch`, priorizando `/usr/bin` antes de iniciar PyInstaller.
2. Reexecutar `mise run mac:build` sem PATH manual.
3. Não modificar nem remover o wrapper pessoal fora do repositório.

Status: corrigido e validado. `mise run mac:build` passou sem PATH manual; artefato Release e sidecar foram produzidos.

### P1 corrigido — imagens EPUB perdem o caminho correto no fallback Swift

Evidência: ao abrir o EPUB real de `Downloads/Ebooks/The Lord of the Rings...epub`, o log registrou membros como `Users/pietropugliesi/Developer/Epub-to-Mp3/OEBPS/images/Art_P020.jpg`, que não existem no ZIP; o ZIP real contém `OEBPS/images/...`.

Correção:

1. O fallback lista entradas do ZIP uma vez por capítulo.
2. Resolve primeiro o candidato exato e, quando Foundation acrescenta um prefixo absoluto do filesystem, escolhe o maior sufixo que coincide com um membro do ZIP.
3. Testes cobrem capítulo `OEBPS/text` + `../images`, prefixo absoluto contaminado e todos os testes existentes do fallback.

Validação: `EpubFallbackParserTests`: 17 testes executados, 0 falhas.

### P1 corrigido — `PERSISTENT_ROOT` não isolava cache/output no CLI local

Evidência: uma conversão executada com `PERSISTENT_ROOT=/tmp/epub-to-mp3-real-qa` ainda escreveu em `output/` do workspace. `paths.py` calculava `PERSISTENT_ROOT`, mas retornava `PROJECT_ROOT/output` e `PROJECT_ROOT/.cache` enquanto não congelado.

Correção:

1. `_resolve_output_dir()` e `_resolve_cache_dir()` agora usam `PERSISTENT_ROOT` quando existe override explícito, preservando `OUTPUT_DIR`/`CACHE_DIR` como overrides de maior prioridade.
2. Teste em subprocesso evita reload de módulo e cobre os três paths.

Validação: teste de override passou; nova conversão real escreveu somente em `/tmp/epub-to-mp3-real-qa/output` e `.cache`, com 3 MP3s e validação 100%.

### Itens a descobrir durante a QA

- Importação por picker e por abrir arquivo; duplicação por hash; PDF e EPUB.
- Busca, limpeza, filtros de tag, ordenação, edição de tags e remoção.
- Reader paginado/contínuo, chrome, TOC, busca, mudança de capítulo, retomada e PDF.
- Conversão Edge/Piper, estados de aquecimento, erro, retry e capítulos selecionados.
- MP3: arquivo gerado, duração, codec, não-silêncio, fila, play/pause, seek, velocidade, capítulo anterior/próximo e retomada.
- Jobs, SSE, logs, telemetria, download/cancelamento/limpeza.
- Settings: backend, sidecar, cache, storage, reader, cloud/advanced e persistência.
- Acessibilidade dos controles essenciais e comportamento em estados vazios.

## Matriz de execução

1. Lançamento macOS e smoke da janela.
2. Navegação: Reader, Library, Conversions, Settings.
3. Library: importar EPUB/PDF de Downloads, buscar, ordenar, filtrar tag, editar tag, remover e reabrir.
4. Reader: abrir, rolar/paginar, esconder/restaurar chrome, TOC, busca, voltar à biblioteca.
5. Conversão: selecionar arquivo, engine, capítulo 1, iniciar, acompanhar progresso e erro/sucesso.
6. Áudio: validar MP3 com `ffprobe`, tocar trecho curto, play/pause, seek, velocidade, capítulo e mini/full player.
7. Jobs: refresh, detalhe, SSE, logs, telemetria, download all, cancel e clear.
8. Settings: toggles/pickers/text fields, cache/storage e sidecar.
9. Backend/web: health, API principal, teste real de conversão e smoke da web UI.
10. Regressão: suíte completa, build macOS normal, verificação de artefatos, processos e estado final do git.

## Ordem de implementação

- [x] Registrar baseline e bloqueadores iniciais.
- [x] Corrigir janela macOS e adicionar regressão; aceite visual live bloqueado por display inativo.
- [x] Tornar build macOS robusto ao PATH e validar a task normal.
- [x] Corrigir resolução de imagens no fallback EPUB e adicionar regressão.
- [x] Corrigir isolamento de `PERSISTENT_ROOT` e validar conversão/áudio real em raiz temporária.
- [ ] U0 — fechar o inventário da árvore local e separar escopos sem descartar alterações.
- [ ] U1 — aceitar no device a camada UIKit do reader: page-curl, scrolling e PDF.
- [ ] U2 — aceitar interações: links, imagens, long-press/Tocar daqui, crossing, chrome, TOC e busca.
- [ ] U3 — auditar `PlaybackClock`, duração, resume, tasks assíncronas e eixos de índice.
- [ ] U4 — provar offline/download/eviction end-to-end com rede desabilitada.
- [ ] U5 — reclassificar os bugs históricos; corrigir somente os reproduzidos e adicionar regressão.
- [ ] U6 — executar gates de host, build genérico iOS, appex, iPhone físico, macOS e suíte final.
- [ ] U7 — somente se necessário, decidir e planejar migração UIKit integral separadamente.

## Critério final

Nenhum “passou” será declarado apenas por inspeção estática. Cada item será marcado como verificado por teste automatizado, execução live, ou bloqueado com a causa explícita. O relatório final listará correções, evidências, limitações e qualquer ação que ainda dependa de outro dispositivo/serviço.
