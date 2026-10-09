# App delivery backlog

Current user requirements override the historical backlog below. Workflow:
Pending → In progress → Verification → Done, or Blocked with evidence/next action.
Every concrete user request/correction belongs here. Completion requires relevant
tests, cross-platform parity, and commit/push evidence; source presence is not done.
Codex owns Apple implementation; Arch owns Rust/Flutter coordination. Both update
this board and `handoff.md` before crossing ownership or changing shared contracts.

## Active requests — 2026-10-08

- [x] **APP-20261008-13 — Faster Apple download/extraction defaults.** Recorded.
  Prefer xcodes/aria2 downloads and experimental unxip for Xcode `.xip` archives.
  CLI help confirms the flag; `/usr/local/bin/aria2c` exists. Runtime `.dmg`
  installation does not use unxip. Retain active useful partial downloads and
  serialize heavy work on this Mac; this policy is not a speed benchmark claim.

- [ ] **APP-20261008-12 — Lightweight legacy iOS Simulator intermediate goal.** In progress.
  Latest user correction: all subsequent iOS validation uses Simulator only, not
  the physical iPhone. Install the oldest compatible runtime and use one small-screen
  iPhone; launch and run focused native app tests without opening Xcode GUI.
  This Intel Mac has 8 GiB RAM and reported crashes with iOS 18/26: no automatic
  fallback to those runtimes, no concurrent heavy jobs, no Python or data deletion.
  App deployment floor: iOS 15.0. Installed runtimes: 18.6 and 26.3, both stopped.
  Determine actual host/toolchain runtime compatibility before booting anything.
  Goal service rejected a second active goal; track this as an intermediate slice
  of the existing quality/performance goal, without marking that goal complete.
  Standard `xcodebuild -downloadPlatform ...15.0` returned unavailable. Official
  legacy catalog supplied iOS 15.0 build 19A339 (5,304,795,932-byte DMG), downloaded
  under `.reports/simulator-ios15/`; hdiutil checksum and Apple package signature
  verified. Installer estimates 11,252,916 KiB installed. No runtime booted.
  Correction: recommending `installer -target /` was wrong. PackageInfo has no
  install destination and payload starts at `Contents`; user-authorized installer
  PID 43721 logged protected system-volume rejection on 2026-10-08 22:04:58.
  Runtime is not installed. CLI `-importPlatform` also rejected this legacy package
  DMG (SimDiskImageError 10). Do not retry root installation or alter system protection.
  Apple documents iOS 15 Simulator unsupported on Sonoma; host compatibility must
  be checked separately from the app's iOS 15 deployment floor.
  Next candidate: iOS 16.0 and a small compatible device. CLI download returned
  unavailable; official legacy URL redirects to Apple Developer unauthorized page.
  Direct curl required authentication, but xcodes 2.1.0 successfully downloaded
  and installed iOS 16.0 (20A360); simctl reports Ready. Earlier download blocker
  was not exhaustive: prefer xcodes rather than transferring legwork to the user.
  Created SE second generation `381DBE17-FFAB-4A2E-B35F-AB9FEC92C14E` (first-generation
  SE does not support iOS 16). Boot began migration, but host load rose from 1.93
  to 62.95 without parallel builds. Shut down the exact device immediately;
  do not interpret bootstatus's shutdown terminal message as successful readiness.
  App opening/tests remain unverified: unsafe observed host load and no compatible
  app/Rust Simulator artifact. No iOS 18/26 boot or physical-device run.
  Full embedded runtime validation also requires the missing Intel iOS Simulator
  Rust artifact (`x86_64-apple-ios`); Arch owns that build. Physical arm64 iOS and
  x86_64 macOS binaries are not substitutes. App launch/tests remain unverified.

- [x] **APP-20261008-11 — Faster compatible fulltext cache decode.** Verified cache behavior.
  Binary plist primary, fallback to existing durable/legacy JSON; preserve older
  bytes during migration, atomic writes and format-aware scoped cleanup/budget.
  Verify native roundtrip fidelity, migration/corruption/removal and same-book
  two-host readiness. No source/model/download changes or Rust/Flutter execution here.
  Mac: 13 cache/native-window tests passed, zero skips (`21-37-41` xcresult).
  Two-host run `reader-relaunch-86F998D4-805C-4493-A999-99819BB90ED9` prepared
  successfully; LOTR improved 439→355 ms but still fails unchanged 200 ms budget.
  Physical iOS `E28AEFD2-00D3-4336-B79F-DD9AC2ACC6F4`: 17 passed, zero failures/skips,
  including cache, renderer and actual UIKit window. Total 42.80 s (build 28.04 s,
  tests 11.17 s); no conversion. Binary cache slice verified for both Apple clients.
  Further latency work remains necessary under APP-20261008-07; no 200 ms claim.
  Removed duplicate pre-lookup signature computations without changing the
  post-await validation; five native renderer tests passed (`21-47-20` xcresult).
  Retested same two hosts in `reader-relaunch-20E82812-A483-459F-87D0-0A751F1C2D32`;
  200 ms acceptance still fails. No speedup/completion claim from this change.
  Signature micro-optimization remains a separate uncommitted renderer slice.

- [x] **APP-20261008-10 — Integrate prepared chapter restoration in Apple readers.** Verified behavior.
  Shared renderer binds complete chapter/settings/font/platform inputs; memory hits
  stay synchronous, disk IO is bounded off-main, archive restoration stays MainActor.
  Both controllers fence stale load generations and retain image/plain/HTML fallback
  and existing viewport geometry. Envelope v2 checks archive SHA256 before decoding.
  Mac storage/renderer/window verification: 17 passed, zero skips (`21-27-36` xcresult).
  Physical iOS focused set: 17 passed, zero skips (`CAB5B9A6-A73C-4299-9E4D-3C3EF9A7451D`),
  plus actual UIKit window integration passed (`2898D60B-28A6-49E6-8465-9442DD25EEA9`).
  UIKit archive comparison initially failed on fixed color representation; normalized
  fixed colors to public sRGB UIColor while retaining dynamic colors, kept full
  equality checks and passed. Native UI fixture explicitly drives its layout passes.
  Two-host native measurement `reader-relaunch-353E8583-ECE5-49E7-9B93-0F7B7A9BF19B`:
  prepare passed; verify remains red, LOTR 439 ms >200 ms. No threshold relaxation,
  budget remains in APP-20261008-07; this completes restoration behavior, not 200 ms.

- [x] **APP-20261008-09 — Safe prepared chapter archive persistence.** Verified.
  Shared Apple actor; immutable archive bytes, book/chapter/signature binding,
  bounded reads, atomic writes, corrupt/mismatch cache misses and owned-only removal.
  Verify isolated native durability, preservation, symlink/size guards and off-main IO.
  No reader fast-path integration or 200 ms claim in this storage slice.
  Nine native macOS tests passed, zero skips (`20-34-11` xcresult). Default 64 MiB
  budget rejects new writes without eviction; file reads/writes cap at 8 MiB.
  Physical iOS storage tests passed in the focused set above. Envelope v2 adds
  archive checksum validation; earlier locked attempt did not build or test.

- [ ] **APP-20261008-07 — Verify native reader readiness after process relaunch.** In progress.
  Two separate native macOS XCTest host executions, same hash-checked LOTR/Christie
  inputs and test-only book IDs. Require disk-prepared content and controls within
  200 ms in the new process; no in-memory prewarm substitute. Preserve all existing
  cache/library data, restore reader defaults and remove only owned test fixtures.
  Red: prepare passed one native test; verify failed one (zero skips), actual
  disk-prepared open 2446 ms >200 ms. Evidence:
  `.reports/mobile-audio/reader-relaunch-628B5899-4B2F-442D-9526-C40779A7AA43`.
  Relaunch test implemented; overall 200 ms acceptance remains unverified/failed.
  Removing redundant MainActor cache rewrite reduced one LOTR sample to 985 ms,
  still failing. Focused profile `reader-relaunch-17AFA62C-9C7B-44CF-951F-9AD1BC083342`:
  LOTR read/decode 241 ms, HTML render 537 ms, TextKit fit 1.6 ms; Christie
  18/16/10 ms. Temporary probes removed. Relaunch test remains uncommitted;
  decoding/render preparation, not viewport layout, needs further work.
  Codec experiment verified: actual typed JSON/plist roundtrips preserve all fields,
  one native test passed with zero skips (`reader-relaunch-3071CE3E-E1C4-4571-9172-948B12E9C8B1`).
  LOTR JSON decode ~213 ms versus binary ~104–118 ms; binary grew 25.09→26.54 MB.
  No production cache migration: this alone cannot fix the 537 ms HTML render.
  Prepared native attributed-text experiment passed one test, zero skips
  (`reader-relaunch-39737E0E-1C15-4C50-9581-006E94EEEB92`): LOTR chapter 8
  HTML render 594 ms vs secure archive decode 0.40–0.65 ms (11,702 bytes);
  Christie chapter 6 16.16 ms vs 0.38–0.55 ms (17,194 bytes).
  Full text/attribute equality checked on each decode. In-memory experiment only;
  durable integration, settings invalidation and actual relaunch remain pending.

- [x] **APP-20261008-08 — Avoid redundant Mac reader cache writes.** Verified.
  Disk-prepared content no longer reencodes/writes/enumerates cache on MainActor.
  Native window regression asserts readable content/controls and unchanged durable
  bytes/mtime: one test passed, zero skips, `20-20-19` macOS xcresult.
  Cold imports still persist; iOS persistence was already dispatched off-main.
  This IO correction does not satisfy APP-20261008-07's 200 ms relaunch budget.

- [ ] **APP-20261008-06 — Investigate slower LOTR adaptive conversion on Arch.** Pending.
  Physical candidate `699FF2AE-0A79-406A-889C-FEF3EF01110F` passed one benchmark,
  zero skips, exact LOTR 8–9/Christie 6–7, no audio reuse. LOTR 310.40→432.12 s
  (+39.2%); Christie 6.34→6.35 s. Initial Edge replies were much slower than baseline;
  profile shrank 4096/2→2048/1 without recorded retries/throttles. This one network
  sample does not isolate policy causality. Arch owns Rust diagnosis/verification;
  retain ordered output and pressure/cancellation behavior, measure controlled
  throughput before changing adaptation. Apple revalidates the resulting artifact.

- [x] **APP-20261008-05 — Preserve manual Mac conversion inbox inputs.** Verified.
  Audit found `ConvertViewModel.importForConversion` removes the entire inbox
  before copying. Acceptance: earlier files survive successful/failed subsequent
  imports and reimport from within the inbox; cleanup targets only owned staging.
  Verify at the actual native import boundary with isolated files.
  Compatibility helper only: current UI has no caller. Three native regressions
  reproduced lost prior inputs/source (`19-31-29` macOS xcresult, all three failed).
  Green: four native tests passed, zero skips (`19-32-33` macOS xcresult).
  Each import retains its own UUID directory; failed copies remove only that directory.

- [ ] **APP-20261008-01 — Two books per library row.** In progress.
  Acceptance: exactly two book cards per row on iOS, macOS and Flutter, including
  narrow/wide widths and resizing; retain cover ratio, labels and existing actions.
  - [x] iOS: 18 physical XCTest passed, zero skips; `E539FCA1-3855-46EC-8AA2-C78BBC31D31D`.
  - [x] macOS: actual NSCollectionView resize regression passed (1 test, zero skips),
    `Test-EpubToMp3Mac-2026.10.08_19-22-48--0300.xcresult`; stale document width fixed.
  - [ ] Flutter (Arch only): widget regression implemented for phone/wide resize;
    run `flutter test test/library_screen_test.dart --plain-name 'library grid keeps two columns across phone and wide resize'` on Arch, not this Mac.
  - [ ] Delivery: inspected diff, synchronized behavior, commit/push.
- [ ] **APP-20261008-02 — Quality/performance goal.** In progress.
  Acceptance/evidence: `docs/plans/2026-10-08-app-quality-performance.md`.
  Remaining: relaunch readiness and the observed conversion performance regression.
  Full physical seven-class sequence passed: `D379076E-DD02-49A1-9DA3-BAA4C728648F`,
  112 passed, zero failures, one opt-in existing-audio measurement skipped;
  no rebuild, 54.64 s total. Earlier playback failures did not reproduce.
  Bounded physical synthesis comparison completed: `699FF2AE-0A79-406A-889C-FEF3EF01110F`,
  exact four playable chapters, one passing test, zero skips, 451.39 s total,
  no rebuild/audio reuse. See APP-20261008-06; performance is not marked resolved.
  Latest device evidence: `0132B263-6FB2-49B1-A195-9627078459AE` (two tests passed)
  and `B882C802-84BE-4447-A0BD-23387F54BFF1` (35 seek tests passed), zero skips.
  Replacement-player regression and initial AVPlayer diagnostics verified on iPhone;
  the suspected old-player session failure did not reproduce. The full sequence
  also passed above; neither establishes the earlier failure's root cause.
  Lifecycle termination barrier: one macOS XCTest passed, zero skips,
  `Test-EpubToMp3Mac-2026.10.08_19-25-41--0300.xcresult`. The isolated regression
  invokes the real termination callback while index encoding is blocked.
  iOS lifecycle: three physical tests passed, zero skips,
  `E06BBEA9-291E-41F8-A2B8-8BBE5D3890E9` (33.64 s total, 24.51 s build,
  7.51 s test interval). Real termination/background callbacks flush isolated
  queued changes; stale generation cannot end its replacement grant. Expiration
  logic is invoked directly, not delivered by the OS. Conversion comparison pending.
  Conversion report instrumentation: three native report/monotonic delivery tests
  passed (`19-28-01` macOS xcresult), plus real task_info capture passed (`19-28-53`),
  zero skips. Added point-sampled footprint and first published-chapter callback
  latency; neither is acoustic latency/peak memory or a baseline comparison.
- [x] **APP-20261008-03 — Shared request tracking and platform parity policy.**
  Registered in `CLAUDE.md`/`AGENTS.md`, this board and `handoff.md` for Codex/Arch.
  Verified by documentation read-back and scoped `git diff --check`; historical instructions
  do not authorize CI/PR monitoring, Python/Ruff local execution or Simulator use.
- [x] **APP-20261008-04 — Host ownership correction.** Registered.
  This Mac performs macOS/iOS work only. Arch performs Rust/Flutter execution and
  validation. Flutter checks remain pending until Arch returns actual test evidence.
  Every future concrete user request/correction updates this board automatically.

## Historical backlog (requires revalidation; not current platform scope)

The original iOS-only scope and old verification recipes below are historical.
Current work must keep iOS/macOS/Flutter parity and follow root instructions.

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
