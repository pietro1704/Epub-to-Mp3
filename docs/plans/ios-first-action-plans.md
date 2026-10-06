# Planos de Atuação — iOS primeiro

> Plano canônico para a evolução do app Epub-to-Mp3. Toda nova tarefa deve indicar qual plano e qual etapa está executando.

## Regra de execução

Para cada etapa iOS:

1. Mapear fluxo, símbolos e arquivos.
2. Criar ou ajustar teste de regressão.
3. Aplicar o patch mínimo.
4. Rodar testes focados no host macOS.
5. Fazer build real para iPhone físico; não usar Simulator por padrão neste Mac.
6. Instalar e abrir no iPhone quando a mudança tocar runtime, UI, áudio ou navegação.
7. Validar o comportamento real e registrar bloqueios concretos.
8. Fazer commit focado; depois do push, monitorar CI.

Não considerar uma etapa concluída apenas por compilação ou teste macOS quando ela altera comportamento visual/runtime.

## Estado-base

- Último commit iOS validado no iPhone: `58ae856 test(ios): keep chapter crossing tap outside links`.
- Correção de retorno ao capítulo anterior confirmada no iPhone por duas automações e logs de `FlickerProbe`.
- Nesta execução, a auditoria de índices e a correção de navegação esparsa foram validadas por 54 testes Swift focados, build físico atual e 3 automações UI no iPhone (2 passaram, 1 foi pulada por capítulo de uma página).
- TOC e busca foram adicionados à cobertura física: `testTableOfContentsOpensAndReturnsToReader` e `testInBookSearchOpensAcceptsQueryAndDismisses` passaram no iPhone.
- Áudio com snapshot pendente foi validado no device por `testUpdateSnapshotBuildsQueueWhenFirstPlayableChapterArrives` e `testResumeBeforeFirstPlayableChapterAutoplaysWhenSnapshotArrives`; ambos passaram.
- Log físico mais recente: `/tmp/plan1-flicker-debug.log`; confirmou `current=5 → target=4`, `wantsLast=true`, `startAtLastPage=true` e ausência de `stale`, `spurious` e `empty`.
- O teste Swift físico de contratos que lê arquivos do repositório não é válido no sandbox do iPhone; ele deve permanecer no host. Os testes de índice/cache passaram no device.
- Branch `master` está com alterações locais desta etapa; ainda não foi commitada.
- Destino físico preferencial: iPhone conectado por USB.
- Bloqueio operacional encontrado em 2026-07-22: o iPhone foi detectado e desbloqueado, mas o artefato mais recente (`ios/EpubToMp3/.build-nosim-noassets/Build/Products/Debug-iphoneos/EpubToMp3.app`) não possui assinatura (`No code signature found`).
- A assinatura local também não está alinhada ao projeto: `project.yml` declara o Team ID `HHRZ35A37Y`, enquanto o Mac só possui o certificado `Apple Development: Pietro Pugliesi` do Team ID `RHXBMZN968`; não há provisioning profiles locais.
- Um build físico normal ainda aparece inelegível porque o Xcode local não tem a plataforma/destino iOS 26.2 instalado. Não baixar runtime nem usar Simulator neste Mac sem autorização explícita.
- Próximo passo bloqueado: confirmar se é autorizado usar o Team ID do certificado local (`RHXBMZN968`) e `-allowProvisioningUpdates` para o Xcode tentar criar/baixar os perfis de desenvolvimento do bundle `com.pietrocode.epubtomp3` e do widget, ou fornecer um artefato já assinado/perfis compatíveis.
- Após a autorização, o build direto para `iphoneos` confirmou que a chave privada do certificado existe, mas o Xcode retorna `No Account for Team "RHXBMZN968"` e não consegue gerar profiles. O artefato não foi criado; o projeto temporariamente alterado para contornar o asset catalog foi restaurado.
- Ação necessária do operador: adicionar no Xcode uma conta Apple que pertença ao Team ID `RHXBMZN968` (ou fornecer profiles de desenvolvimento válidos para `com.pietrocode.epubtomp3` e `com.pietrocode.epubtomp3.widget`), depois repetir o build físico.
- Execução física concluída em 2026-07-22 após a conta ser adicionada: build `iphoneos` assinado com Team ID real `HHRZ35A37Y`, provisioning automático para app/widget, assinatura verificada com `codesign`, instalação confirmada pelo `devicectl` e lançamento confirmado para `com.pietrocode.epubtomp3`. O app foi deixado aberto no iPhone para validação manual.

## Plano 0 — Higienizar o estado local

**Objetivo:** separar mudanças verificadas, mudanças incompletas e alterações não relacionadas.

- Revisar o diff dos arquivos Swift/localização atualmente modificados.
- Identificar a qual feature cada alteração pertence.
- Criar testes para qualquer mudança iOS que permaneça.
- Commitar apenas mudanças verificadas; preservar o restante sem misturar escopos.

**Saída:** working tree compreensível e cada commit representando uma única decisão.

## Plano 1 — Reader e navegação

**Objetivo:** eliminar inconsistências visíveis e de estado no leitor.

### Auditoria de índices — etapa atual

**Matriz obrigatória:**

- `EbookFulltext.Chapter.index`: eixo 1-based recebido do backend.
- `zeroBasedEpubIndex`: eixo 0-based do EPUB/reader.
- `JobSnapshot.playableChapters[index]`: eixo compacto do player; capítulos pendentes podem desaparecer.
- `ReaderCoordinator.anchor.chapterIndex`: deve sempre permanecer no eixo EPUB 0-based.
- `ChapterCacheManager`: deve usar o mesmo eixo do reader para cache/prefetch, sem conversões duplicadas divergentes.

**Achado inicial:** `InstantReaderIndexMapper.playableIndexOrClamped` usa `.nearestPositional` por padrão. Em snapshots esparsos, isso pode tratar um índice EPUB como posição compacta e tocar o capítulo errado. O caminho de recuo já usa `.atOrBefore`; os caminhos de TOC, busca e cache precisam ser auditados individualmente, não corrigidos por uma conversão global.

**Arquivos prioritários:**

- `ios/EpubToMp3/EpubToMp3/Views/InstantReaderView.swift`
- `ios/EpubToMp3/EpubToMp3/Views/PlayerReaderView.swift`
- `ios/EpubToMp3/EpubToMp3/Services/ChapterCacheManager.swift`
- `ios/EpubToMp3/EpubToMp3/Services/ReaderCoordinator.swift`
- `ios/EpubToMp3/EpubToMp3/Models/EbookFulltext.swift`
- `ios/EpubToMp3/EpubToMp3Tests/InstantReaderIndexMapperTests.swift`

**Próximas etapas bite-sized:**

1. ✅ Enumerar cada chamada a `playableIndex`, `epubIndex`, `zeroBasedEpubIndex` e `chapter.index`; marcar o eixo de entrada/saída.
2. ✅ Adicionar testes RED para TOC, busca, prefetch/cache e retorno usando capítulos pendentes/esparsos.
3. ✅ Substituir conversões comprovadamente erradas; manter fallback posicional somente onde a UX o exige.
4. ✅ Rodar `InstantReaderIndexMapperTests`, testes de `AudioPlayer` e `ChapterCacheManagerTests` no host; repetir índices/cache no device.
5. ✅ Build/install e automação física concluídos para avanço/recuo/crossing, TOC, busca e áudio com capítulo pendente entre capítulos reproduzíveis.

**Evidência esperada:** cada ação registra o mesmo capítulo em índice EPUB, título visível e capítulo audível; nenhum capítulo pendente é tocado por engano.

- Validar TOC do top bar, hyperlinks, notas e seleção explícita contra audio-follow.
- Validar crossing forward/backward, paginação final, safe area, chrome e contadores.
- Reproduzir no iPhone os fluxos críticos após cada correção.

**Critério de saída:** navegação sem flicker, sem capítulo/página incorretos e sem sobrescrita indevida da seleção do usuário; todos os eixos de índice têm contrato explícito e testes para snapshots esparsos.

## Plano 2 — Player, fila e read-along

**Objetivo:** manter áudio, cursor e posição visual coerentes.

- Auditar `AudioPlayer` como ponto central de decisão de play/pause/seek.
- Confirmar que o capítulo corrente representa o item audível, não áudio apenas enfileirado.
- Testar divergência reader ↔ player no mesmo capítulo e entre capítulos.
- Validar streaming, queue append, retomada, stop e fallback sem desmontar fila viva.

### Regressão do capítulo 2 — timing sobrescrito por pre-buffer

**Sintoma reportado:** no capítulo 2, a leitura chegava a “untimely end” e
saltava para “some people were rather shocked”, omitindo o trecho entre
“the blame was mostly laid on gandalf. 'if only ...” e “as hobbits say”.

**Causa confirmada no código:** `AudioPlayer.enqueueSegment` recebia segmentos
de capítulos futuros enquanto o capítulo atual ainda estava audível. O código
usava o capítulo do segmento recém-enfileirado para sobrescrever
`segmentChapterIndex`, zerar `segmentCumulativeBase` e substituir
`segmentSentenceIds`. O `SyncEngine`, alimentado pela posição do player,
passava então a consultar o timing do capítulo futuro antes de o
`AVQueuePlayer.currentItem` avançar. O áudio da fila não era necessariamente
perdido; o cursor/read-along saltava por uma faixa inteira de conteúdo.

**Correção aplicada:**

- manter sentence IDs agrupados por capítulo;
- não trocar o capítulo ativo ao enfileirar áudio futuro;
- trocar/resetar o estado de timing somente quando o novo capítulo se torna o
  `currentItem` audível;
- preservar o capítulo e a contagem de frases ativas durante pre-buffer;
- manter mini player e player expandido usando `AudioPlayer.currentChapterIndex`
  como SOT, removendo o fallback paralelo em `UserDefaults`;
- injetar o `ReaderCoordinator` no player expandido para o mesmo roteamento de
  play/divergência usado pelo mini player.

**Regressão:**
`AudioPlayerEnqueueSegmentTests.testBufferingAheadPreservesActiveSegmentTimingChapter`
confirma que segmentos do capítulo seguinte não substituem o timing ativo.
Suite focada executada no host macOS: 9 testes, 0 falhas.

**Bloqueio de validação física:** build/test host inicialmente tentou compilar
asset catalog para `iphoneos` sem runtime de Simulator instalado e falhou antes
dos testes. O teste host foi repetido com remoção temporária e reversível da
referência de `Assets.xcassets` no `project.pbxproj`; o projeto foi restaurado
imediatamente após a execução. A instalação física do novo artefato ainda é
necessária para confirmar o capítulo 2 no iPhone. A tentativa de build físico
posterior também foi bloqueada porque o Xcode marca o iPhone como inelegível
sem a plataforma iOS 26.2 e o build genérico retorna `No Account for Team
HHRZ35A37`/profiles ausentes. Nenhuma plataforma foi baixada e nenhuma conta,
perfil ou configuração de assinatura foi alterada.

**Critério de saída:** cursor, áudio audível, página e ações da UI permanecem coerentes em cold start e durante streaming.

## Plano 3 — Biblioteca, downloads e offline

**Objetivo:** tornar importação, download e leitura local confiáveis no iOS.

- Auditar downloads parciais, retomada HTTP Range, cache e limpeza de órfãos.
- Validar conversão lazy e abertura local pelo TOC.
- Testar estados offline, erro de rede, arquivo incompleto e reabertura do app.
- Confirmar que exclusões não ressuscitam por sincronização/cache.

## Plano 4 — Produção iOS

**Objetivo:** fechar os gates de release depois dos planos funcionais.

- Testes Swift do host e suite relevante do projeto.
- Build Release genérico para iOS.
- Build Debug no iPhone, instalação e lançamento.
- Verificar assinatura, bundle, recursos, permissões e tamanho do artefato.
- Validar UI, áudio, retomada e conversão com evidência atual no aparelho.
- Monitorar CI e corrigir falhas antes de declarar o plano concluído.

## Ordem atual

1. Plano 0 — higienizar o estado local.
2. Plano 1 — reader e navegação.
3. Plano 2 — player/read-along.
4. Plano 3 — biblioteca/downloads/offline.
5. Plano 4 — validação de produção.

Ao iniciar qualquer trabalho, referir-se explicitamente a: `Plano N — nome`, `etapa`, `evidência esperada` e `critério de saída`.
