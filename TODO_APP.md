# TODO — Epub-to-Mp3

> Gerado em 2026-07-10. Fonte: BUG_SPRINT.md/TDD_PLAN.md do iOS estão 100%
> resolvidos (bugs 1-8, ver commits 2d0cf59..8a179ae) — não há bug conhecido
> aberto. Os itens abaixo são gaps de escopo/arquitetura identificados via
> memória do projeto + estado atual do repo (sem TODO/FIXME reais no código).
> Edite livremente antes de rodar o prompt no final.

## Itens a resolver (foco: iOS)

> Flutter/multiplataforma fora de escopo por ora — foco no app iOS/iPadOS.

- [x] **2. WidgetKit / Live Activity — já implementado (verificado 2026-07-10)**
  Item estava desatualizado: o target `EpubToMp3Widget` já existe em
  `ios/EpubToMp3/EpubToMp3Widget/` (home-screen widgets — `EpubToMp3Widget`,
  `NowPlayingWidget`, `ContinueReadingWidget`, `LibraryWidget` —, lock-screen
  `.accessoryCircular/Rectangular/Inline` via `NowPlayingLockScreenWidget`,
  e Live Activity de conversão via `ConversionLiveActivityWidget`), com
  App Group `group.com.pietrocode.epubtomp3` e sync em
  `EpubToMp3/Services/WidgetDataSync.swift`. Confirmado nesta passada:
  `xcodegen generate` → build Debug → install → launch no device físico
  (`00008140-001128A022BA801C`) sem erros, e os 9 testes de
  `WidgetDataSyncTests` passam no device. Nenhum código novo foi necessário.

- [ ] **3. Download/cache offline em disco não auditado recentemente**
  `offline-cache-mobile` (download manager, fila de transferência, eviction)
  é mencionado como escopo mas não há evidência recente de implementação
  completa — `ChapterCacheManager.prefetchNext` foi *removido* do
  auto-trigger (Bug 6 do bug sprint), mas não está claro se existe um
  fluxo explícito "baixar para ouvir offline" com fila/retomada.
  Verificar estado atual antes de agir.
  Agente sugerido: `offline-cache-mobile`.

- [ ] **4. Auditoria de acessibilidade (VoiceOver/Dynamic Type) pendente**
  Não há registro de uma passada recente do `ios-accessibility-auditor`
  neste app. Antes de qualquer release para TestFlight/App Store, validar
  VoiceOver labels/hints/traits nos controles de player e reader,
  Dynamic Type em XXXL (há comentários no código citando XXXL mas não
  confirma cobertura de VoiceOver), contraste de cor, reduce motion.
  Agente sugerido: `ios-accessibility-auditor`.

- [ ] **5. Auditoria de segurança / CVEs pendente**
  Último commit relevante de dependência é bump de rotina (dependabot).
  Não há registro de rodada completa de `security-auditor` (pip-audit +
  npm audit + CodeQL/Dependabot abertos + secrets no repo) recentemente.
  Rodar antes do próximo release.
  Agente sugerido: `security-auditor`.

- [ ] **6. (adicione aqui um item seu — bug relatado, feature pedida, etc.)**

- [ ] **7. (espaço livre)**

## Fora de escopo por ora

- Cliente Flutter (Android/Linux/Windows) — retomar quando priorizarmos multiplataforma.

## Prompt para o Claude

```
Resolva os itens marcados [ ] em TODO_APP.md, um de cada vez, na ordem em
que aparecem. Para cada item:

1. Se o item referenciar um agente sugerido, lance-o via Agent tool com um
   prompt específico e autocontido (não delegue "entenda e resolva" —
   escreva o contexto já levantado aqui).
2. Antes de codar, confirme o estado atual do repo (o item pode já estar
   parcialmente resolvido ou desatualizado — verifique antes de assumir).
3. Diagnostique a causa raiz (se for bug) ou desenhe o escopo mínimo
   (se for feature) antes de alterar código.
4. Implemente o fix/feature mínimo necessário — sem abstrações
   especulativas, sem gold-plating.
5. Adicione/atualize teste de regressão cobrindo o caso (obrigatório —
   ver Testing Policy do CLAUDE.md).
6. Rode a suíte relevante (`mise run test`, ou testes específicos da
   plataforma) e confirme verde antes de prosseguir.
7. Para mudanças iOS: build → install → launch no device físico e
   confirme visualmente antes de declarar resolvido (nunca declarar
   fixed só com base em compilação/testes unitários).
8. Faça commit focado (mensagem em inglês, foco no "porquê", não no "o quê").
9. Marque o item como [x] neste arquivo e adicione uma linha de status
   (data + hash do commit) logo abaixo dele.

Pare e pergunte se um item depender de decisão de produto/escopo que não
esteja clara neste arquivo (ex: qual plataforma priorizar no Flutter).
```
