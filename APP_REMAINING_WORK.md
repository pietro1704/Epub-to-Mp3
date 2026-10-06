# Epub-to-Mp3 — o que ainda precisa ser arrumado

> Backlog técnico e de produto para orientar as próximas sessões com Hermes.
>
> Atualizado em 2026-07-21, a partir do estado live do repositório, da árvore de trabalho e dos documentos existentes.
>
> Regra principal: nenhum item é considerado resolvido apenas porque compila ou porque existe um teste unitário. Bugs de UI, áudio, layout e ciclo de vida precisam ser reproduzidos na plataforma real quando indicado.

> Fonte de execução: `CLAUDE-MINI-PROMPT.md` contém o loop operacional curto;
> `CLAUDE-PROJECT-BRIEF.md` contém arquitetura estável. Este arquivo contém
> backlog, evidências, aceite e decisões. Se houver conflito, o código verificado
> live vence a documentação antiga; a autorização atual do usuário vence regras
> históricas de commit/push.

## Última verificação live

- Python completo: `mise run test:unit` passou com 1853 testes, 2 skipped e 3
  subtests; o fallback Edge→Piper ficou determinístico no teste de regressão.
- Integração Python: 28 passaram e 1 foi pulado.
- Web: lint sem warnings, 142 testes passaram e o build de produção passou.
- Não há gate técnico vermelho neste estado; validação física iPhone/HF continua
  dependente dos ambientes respectivos.

## Como usar este arquivo com Hermes

Use esta instrução para executar uma fatia, não o backlog inteiro em one-shot:

```text
Leia `APP_REMAINING_WORK.md` e escolha o item explicitamente indicado pelo
usuário; se ele pedir continuidade sem indicar item, use a ordem recomendada.

Antes de alterar qualquer arquivo:
1. Verifique `git status`, branch e os arquivos envolvidos.
2. Leia o código e os testes atuais; não confie cegamente em documentos antigos.
3. Classifique o item como CONFIRMADO, REPRODUZIDO, DESATUALIZADO ou HIPÓTESE.
4. Se o item for ambíguo ou exigir decisão de produto, pare e pergunte.
5. Para bug, escreva/atualize primeiro um teste de regressão ou um roteiro mínimo de reprodução.
6. Faça a menor correção que resolve a causa raiz.
7. Rode a verificação específica e depois a suíte relevante.
8. Para iOS, faça build, instale e valide no dispositivo físico; não use Simulator neste Mac sem autorização explícita.
9. Não faça reset, descarte de alterações ou mudanças remotas sem pedido explícito.
   Commit, push e PR também exigem autorização explícita para a sessão.
10. Atualize este arquivo somente depois de verificar o resultado, registrando evidência objetiva.

Ao terminar, informe: classificação, causa, arquivos alterados, testes executados,
resultado observado, limitações, rollback e próximo item recomendado. Atualize
o status somente com evidência; não marque resolvido por inferência.
```

## Estado atual que deve ser preservado

- Há alterações locais extensas e ainda não commitadas, principalmente no reader/player SwiftUI, cache, resume, HTML/CSS EPUB, localizações e testes.
- Existe um arquivo novo não rastreado: `READER_LAYOUT_RESUME_HTML_PLAN.md`.
- Não misturar o backlog com a revisão/commit dessas alterações locais.
- Não assumir que `TODO_APP.md`, `BUG_SPRINT.md` ou `AUDIT-0.4.0.md` refletem completamente o estado atual; eles contêm itens de épocas diferentes.

## Prioridade 0 — fechar o estado atual antes de novas features

### APP-001 — Validar no iPhone as alterações de reader, resume e HTML/CSS

- **Status:** ABERTO — implementação local extensa, validação funcional ainda é o gate.
- **Evidência:** `READER_LAYOUT_RESUME_HTML_PLAN.md` registra build físico e instalação, mas deixa como próxima etapa a validação manual com o EPUB real.
- **Arquivos:**
  - `ios/EpubToMp3/EpubToMp3/Services/AudioPlayer.swift`
  - `ios/EpubToMp3/EpubToMp3/Services/EpubHtmlRenderer.swift`
  - `ios/EpubToMp3/EpubToMp3/Services/ReaderCoordinator.swift`
  - `ios/EpubToMp3/EpubToMp3/Services/ResumeStore.swift`
  - `ios/EpubToMp3/EpubToMp3/Views/ReaderView.swift`
  - `ios/EpubToMp3/EpubToMp3/Views/InstantReaderView.swift`
  - testes Swift correspondentes
- **Validar no device:**
  - abrir o capítulo real `The Shadow of the Past`;
  - conferir título, CSS, justificação e recuo;
  - alternar Paginated/Scrolling;
  - fechar/reabrir no mesmo capítulo e página;
  - fechar pausado e confirmar posição exata;
  - fechar tocando e confirmar retomada aproximadamente 15 s antes;
  - pausar e confirmar ausência de áudio residual.
- **Aceite:** todos os fluxos acima funcionam no iPhone; qualquer falha ganha teste reproduzível e correção separada.
- **Verificação:** build físico + instalação + launch + validação manual documentada; `pytest` focado e testes Swift disponíveis.

### APP-002 — Revisar e separar as alterações locais antes de consolidar

- **Status:** ABERTO.
- **Evidência:** `git status` mostra dezenas de arquivos modificados em múltiplas áreas.
- **Objetivo:** detectar regressões, mudanças acidentais, traduções incompletas e testes que não correspondem ao comportamento real.
- **Aceite:** `git diff --check` limpo; cada grupo de mudança tem testes; nenhuma alteração não relacionada entra no mesmo conjunto.
- **Não fazer automaticamente:** commit, push, reset ou descarte de alterações.

### APP-012 — Fazer o download offline ser realmente consumido pelo player

- **Status:** CONFIRMADO INCOMPLETO — P0.
- **Evidência:** `DownloadManager.swift:85-128,242-269` grava MP3 e `manifest.json` em disco, mas `AudioPlayer.swift:832-835` monta itens a partir de `chapter.downloadUrl`; `PlaybackRouter.route` não tem integração confirmada com o player; `PlaybackRouterTests.swift` registra que essa integração ainda é futura.
- **Impacto:** o app pode mostrar download concluído e ainda depender da URL remota para tocar.
- **Aceite:** com a rede desabilitada, audiobook previamente baixado reproduz os capítulos disponíveis; o player prefere arquivo local validado e só cai para URL remota quando não houver cópia local.
- **Testes:** arquivo local presente, ausente, parcial/corrompido e ausência de rede.
- **Dependência:** APP-001 e APP-008.

### APP-013 — Fazer merge correto dos downloads parciais

- **Status:** CONFIRMADO INCOMPLETO — P0.
- **Evidência:** `DownloadManager.swift:224-226,306-313` inicia cada execução com `entries = []` e salva manifesto somente com os capítulos daquela execução; `PlayerReaderView.swift:742-768` pode marcar um download de capítulo único como `cachedOffline = true`.
- **Impacto:** baixar capítulo 1 e depois capítulo 5 pode apagar o capítulo 1 do manifesto; download parcial pode ser apresentado como audiobook totalmente offline.
- **Aceite:** manifestos fazem merge idempotente; capítulos já baixados permanecem reconhecidos; `cachedOffline` só é verdadeiro quando todos os capítulos obrigatórios existem; a UI diferencia completo de parcial.
- **Testes:** download completo seguido de seletivo e seletivo seguido de completo.

### APP-014 — Tornar download interrompido retomável e seguro em background

- **Status:** CONFIRMADO INCOMPLETO — P1.
- **Evidência:** `DownloadManager.swift:355-369` usa `URLSessionConfiguration.default` e `session.download(from:)`; não há `resumeData`, `URLSessionDownloadDelegate`, `Range`, `background(withIdentifier:)` ou equivalente.
- **Impacto:** suspensão, encerramento ou falha de rede reinicia o capítulo desde o início e pode confundir arquivo parcial com MP3 completo.
- **Aceite:** retoma do byte recebido quando o servidor suportar Range; arquivo temporário nunca é tratado como completo; comportamento em background é determinístico e documentado.
- **Teste:** servidor local que interrompe a transferência e valida a retomada.

## Prioridade 1 — funcionalidade que atualmente não existe ou é incompleta

### APP-003 — Implementar fallback Piper real no iOS ou declarar o limite do produto

- **Status:** CONFIRMADO INCOMPLETO.
- **Evidência:** `ios/EpubToMp3/EpubToMp3/Services/PiperBridge.swift` lança `PiperBridgeError.notImplemented` em todas as sínteses; `ios/PIPER-EMBED.md` classifica o estado como stub-only.
- **Impacto:** o app iOS depende efetivamente de Edge-TTS; conversão offline/fallback não é utilizável.
- **Escopo técnico já documentado:** ONNX Runtime, espeak-ng, encoder MP3, modelos e integração do transporte.
- **Aceite:** síntese real de pelo menos `pt-BR` e `en-US`, com teste de áudio não vazio/válido, fallback integrado e medição de tamanho/tempo do app.
- **Alternativa válida:** se não for prioridade, remover a promessa de fallback offline da UI/documentação e registrar explicitamente a limitação.
- **Dependência:** decisão de produto sobre aumento de tamanho do app e download de modelos.

### APP-004 — OCR para PDFs escaneados

- **Status:** CONFIRMADO AUSENTE.
- **Evidência:** `ios/EpubToMp3/EpubToMp3/Services/PdfTextExtractor.swift` informa que OCR ainda não é suportado.
- **Impacto:** PDFs só-imagem são importados, mas não viram audiobook.
- **Aceite mínimo:** detectar PDF sem texto antes da conversão; oferecer OCR local suportado ou erro acionável recomendando OCR/fonte melhor; nunca gerar audiobook vazio.
- **Testes:** PDF textual, PDF escaneado, PDF protegido e falha de OCR.

### APP-005 — Fechar gaps de entrada do Android/Flutter

- **Status:** CONFIRMADO NO INVENTÁRIO, IMPLEMENTAÇÃO PRECISA SER REVALIDADA.
- **Fonte:** `docs/plans/2026-07-15-ios-android-parity.md` e `flutter_app/MIRROR-MAP.md`.
- **Ordem recomendada:**
  1. consumir `ACTION_VIEW`/`ACTION_SEND` e persistir documentos `content://`;
  2. leitor visual de PDF;
  3. áudio em background, MediaSession, lock screen e audio focus;
  4. jobs locais persistentes com retry/cancel/watchdog;
  5. fallback TTS offline;
  6. notificação de conversão, widgets e deep links;
  7. Jobs/logs/telemetria e tela de conversão manual.
- **Arquivos de referência:** `flutter_app/lib/`, `flutter_app/android/`, `flutter_app/MIRROR-MAP.md`.
- **Aceite:** cada gap confirmado tem teste Dart/Flutter e validação em build/device Android real.
- **Restrição:** não começar pelo espelhamento visual de todas as telas; priorizar entrada, áudio e conversão utilizável.

## Prioridade 2 — bugs e riscos do reader que exigem reprodução atualizada

### APP-006 — Revalidar interação “Tocar daqui”

- **Status:** PRECISA REPRODUÇÃO; documentação conflitante.
- **Evidência:** `ios/EpubToMp3/BUG_SPRINT.md` lista bugs 7/8 como abertos, enquanto outros documentos posteriores indicam correções parciais e testes novos.
- **Fluxos:** long-press em frase no modo paginado, menu “Tocar daqui”, propagação para player e início no sentence correto.
- **Aceite:** long-press abre ação correta sem seleção acidental; o áudio começa na frase escolhida em `PlayerReaderView` e `InstantReaderView`; cancelamento não altera o player.
- **Regra:** primeiro verificar o código atual e o device; não aplicar automaticamente o patch antigo do `BUG_SPRINT.md`.

### APP-007 — Revalidar links e imagens EPUB no modo paginado

- **Status:** PRECISA REPRODUÇÃO; parser/layout teve mudanças locais recentes.
- **Fluxos:** links internos/externos no `TextKitPageView`; imagens relativas e SVG; EPUB com CSS em ordem variável de atributos.
- **Arquivos:** `EpubHtmlRenderer.swift`, `TextKitPageView.swift`, `AttributedPageView.swift`, `ReaderView.swift`.
- **Aceite:** link não quebra a navegação nem abre URL insegura; imagens aparecem quando existem no EPUB; HTML malformado falha de forma segura.
- **Testes:** fixture EPUB com imagem, link interno e link externo.

### APP-008 — Auditar download offline explícito e prefetch

- **Status:** PRECISA REPRODUÇÃO END-TO-END; os defeitos de integração confirmados estão separados em APP-012, APP-013 e APP-014.
- **Motivo:** o prefetch automático foi alterado/removido em correções anteriores, mas ainda é necessário confirmar a experiência final: baixar para ouvir offline, progresso, retomada, cancelamento, eviction e ausência de download silencioso.
- **Arquivos:** `ChapterCacheManager.swift`, `DownloadManager.swift`, `AudiobookCacheEviction.swift`, telas de reader/player/settings.
- **Aceite:** o usuário sabe quando um download começa; há estado de progresso/erro; capítulos baixados tocam sem rede; cache não remove item em uso; prefetch segue preferência explícita.

### APP-015 — Corrigir risco de eviction durante download/leitura

- **Status:** PROVÁVEL — precisa teste antes de corrigir.
- **Evidência:** `AudiobookCacheEviction.swift:163-195` remove o audiobook por TTL/orçamento; `EpubToMp3App.swift:262-273` protege apenas o `jobId` em reprodução; `DownloadManager.swift:315-320` dispara eviction protegendo somente o novo job.
- **Risco:** livro aberto, download parcial ou síntese ativa podem não ser considerados ativos e ser removidos.
- **Aceite:** download/síntese ativos nunca são removidos; cache aberto é protegido ou a política fica explicitamente documentada; testes cobrem livro ativo, download ativo e cache parcial.

### APP-016 — Sanitizar HTML/CSS de EPUB antes de inserir no leitor web

- **Status:** CONFIRMADO — P0 de segurança.
- **Evidência:** `python_app/server.py:2989-3006` devolve `chapter.raw_html`, CSS e recursos; `web/src/components/EbookReaderPanel.tsx:422-437` injeta conteúdo com `shadow.innerHTML`. Shadow DOM não é uma fronteira de segurança contra conteúdo ativo.
- **Impacto:** EPUB malicioso pode conter `script`, handlers inline, URLs `javascript:` ou CSS abusivo no contexto da aplicação.
- **Aceite:** allowlist explícita para tags/atributos; remover scripts, `on*`, URLs perigosas e elementos ativos; CSS filtrado/isolado; teste com EPUB malicioso confirmando que o conteúdo não executa nem permanece ativo.
- **Regra:** manter recursos legítimos do leitor, como texto, imagens permitidas e links internos seguros.

### APP-017 — Fazer upload streaming com limite de memória

- **Status:** CONFIRMADO — P1.
- **Evidência:** `python_app/src/routes_uploads.py:109-114` e `python_app/server.py:2489-2497` fazem `await file.read()` antes de aplicar o limite; o upload local também lê o arquivo inteiro para hash.
- **Impacto:** uploads simultâneos próximos do limite podem consumir RAM excessiva e derrubar o processo, sobretudo no HF Spaces.
- **Aceite:** gravar em chunks, interromper ao atingir `MAX_UPLOAD_BYTES`, calcular hash incrementalmente e não materializar o payload inteiro; testes de arquivo acima do limite e uploads concorrentes.

### APP-018 — Corrigir `--no-cache` para não apagar livros de terceiros

- **Status:** CONFIRMADO — P1.
- **Evidência:** `python_app/main.py:656-660` remove o diretório compartilhado inteiro com `shutil.rmtree(self.cache_root)` durante conversão de um livro.
- **Impacto:** limpar cache do livro A pode destruir cache do livro B, especialmente em batch.
- **Aceite:** `--no-cache` remove apenas o livro-alvo; uma limpeza global, se necessária, tem opção separada e explícita; testes com dois livros e batch.

### APP-019 — Impedir snapshots antigos de vencerem snapshots SSE novos

- **Status:** CONFIRMADO COMO RISCO — P1; reproduzir com teste determinístico antes do patch.
- **Evidência:** `web/src/hooks/useConversionFlow.ts:865-878,1572-1575,2224-2226` salva `state` capturado por closure; `useConversionFlow.ts:1161-1237` mantém polling HTTP concorrente enquanto SSE está ativo.
- **Impacto:** refresh/resume pode perder progresso; resposta HTTP atrasada pode regredir capítulos concluídos, ETA e percentual.
- **Aceite:** salvar o último snapshot normalizado; usar SSE enquanto saudável e polling apenas após falha/timeout; monotonicidade de progresso; testes com snapshots fora de ordem e cache final após refresh.

### APP-020 — Corrigir documentação e contrato de engines

- **Status:** CONFIRMADO — P1 documental.
- **Evidência:** `web/README.md:14-16` orienta `uvicorn main:app`, embora o app esteja em `python_app.server:app`; `README.md` promete Kokoro, mas `python_app/src/tts/factory.py` expõe Edge/Piper e os stubs Kokoro/Coqui/Spark retornam indisponível.
- **Aceite:** corrigir comando oficial de inicialização; alinhar README, UI, CLI, `/api/voices` e testes sobre engines realmente suportadas; validar startup e `/api/health` em ambiente do projeto.

### APP-021 — Proteger API pública e endpoints administrativos

- **Status:** RISCO CONFIRMADO; decisão de deployment ainda necessária.
- **Evidência:** demo HF expõe conversão/upload/cleanup/restart sem rate limit ou autenticação aparente, conforme `AUDIT-0.4.0.md` e superfície atual de `python_app/server.py`/rotas.
- **Impacto:** abuso pode consumir Edge-TTS, CPU, disco e acionar operações administrativas.
- **Aceite:** definir modo público versus self-hosted; no modo público, limitar IP/jobs/uploads e proteger cleanup/restart; testes de excesso e autorização.

### APP-022 — Remover warnings assíncronos da suíte web

- **Status:** CONFIRMADO COMO DÍVIDA DE TESTE — P2.
- **Evidência:** auditoria executou 137 testes e observou warnings React de atualização de `EbookReaderPanel` fora de `act`.
- **Aceite:** usar `act`, `waitFor` ou `findBy*` corretamente; suíte passa sem warnings assíncronos relevantes.

## Prioridade 3 — qualidade, segurança e release

### APP-009 — Auditoria de acessibilidade real

- **Status:** ABERTO.
- **Escopo:** VoiceOver labels/hints/traits, Dynamic Type até XXXL, contraste, Reduce Motion, foco de teclado no macOS e controles do player/reader.
- **Arquivos:** telas em `ios/EpubToMp3/EpubToMp3/Views/` e componentes de interação.
- **Aceite:** roteiro manual no device + testes/snapshots onde forem confiáveis; nenhum controle essencial sem nome ou ação compreensível.

### APP-010 — Rodar auditoria de dependências e segurança

- **Status:** ABERTO.
- **Escopo:** `pip-audit`, auditoria npm, secrets acidentais, upload/ZIP/HTML, URLs de assets/downloads, CORS/CSRF e limites de memória.
- **Áreas:** `python_app/`, `web/`, `Dockerfile`, endpoints de upload/fulltext/output.
- **Aceite:** relatório datado com vulnerabilidades confirmadas, falso-positivos e correções; não atualizar dependências em massa sem teste.

### APP-011 — Validar build/release de todas as superfícies suportadas

- **Status:** ABERTO.
- **Matriz mínima:**
  - Python: `pytest` e `mise run test`;
  - Web: testes e build de produção;
  - macOS: `mise run mac:build`;
  - iPhone físico: build/install/launch;
  - Android: `flutter analyze`, `flutter test`, build e device quando SDK estiver disponível;
  - HF/Docker: rebuild limpo e smoke test.
- **Aceite:** limitações de ambiente ficam registradas; nenhum “passou” baseado em comando que não foi executado live.

## Itens antigos que não devem ser tratados como backlog confirmado

- WidgetKit/Live Activity: `TODO_APP.md` registra como já implementado; só reabrir se uma regressão for reproduzida.
- Bugs 1–6 do antigo `BUG_SPRINT.md`: verificar o código atual antes de reabrir.
- Itens do `AUDIT-0.4.0.md` sobre CLI, web, Tauri e HF: são candidatos de auditoria antiga, não fatos atuais. Revalidar linhas e comportamento antes de corrigir.
- Flutter mirror map: `TODO` no mapa pode significar “não espelhado”, não necessariamente “quebrado” no produto suportado.

## Ordem recomendada de execução

1. APP-002 — revisar/separar a árvore de mudanças sem apagar trabalho local.
2. APP-016 — bloquear XSS no leitor web antes de expor EPUBs não confiáveis.
3. APP-017 — limitar memória dos uploads.
4. APP-018 — impedir que `--no-cache` apague livros de terceiros.
5. APP-001 — validar no iPhone o trabalho atual de reader/layout/resume.
6. APP-012 e APP-013 — fazer offline funcionar e preservar downloads parciais.
7. APP-006, APP-007 e APP-008 — fechar interações e fluxos end-to-end do reader/player.
8. APP-019 — corrigir ordem/versão de snapshots SSE e polling.
9. APP-020 e APP-022 — alinhar contrato/documentação e zerar warnings web.
10. APP-004 — OCR, se PDF for requisito ativo.
11. APP-003 — Piper iOS, somente após decisão de produto.
12. APP-005 — Android/Flutter, por fatias funcionais.
13. APP-014 e APP-015 — robustez avançada de downloads/cache.
14. APP-009, APP-010, APP-011 e APP-021 — gates de acessibilidade, segurança e release.

## Área de trabalho — Pietro

> Preencha livremente esta seção. Ela é o espaço para decisões, observações de uso, bugs encontrados e mudanças de prioridade. O restante do arquivo é o backlog técnico consolidado.

### Decisões de produto

- **Plataforma prioritária agora:**
- **O que precisa funcionar primeiro para você:**
- **Piper offline no iOS é prioridade?** Sim / Não / Decidir depois
- **OCR para PDF é prioridade?** Sim / Não / Decidir depois
- **Android/Flutter entra nesta fase?** Sim / Não / Decidir depois
- **API pública no HF:** demo pública / uso privado / ainda decidir

### Testes manuais que faltam

- [ ]
- [ ]
- [ ]

### Bugs ou incômodos encontrados

Para cada problema, anote o máximo possível:

```markdown
#### Observação — AAAA-MM-DD

- **O que eu fiz:**
- **O que eu esperava:**
- **O que aconteceu:**
- **Livro/arquivo usado:**
- **Plataforma/device:**
- **Conexão:** online / offline / instável
- **Frequência:** sempre / às vezes / uma vez
- **Prioridade percebida:** P0 / P1 / P2 / P3
- **Screenshot/log:**
- **Notas:**
```

### Itens que quero que Hermes execute

```markdown
1. APP-___ —
2. APP-___ —
3. APP-___ —
```

### Decisões pendentes para perguntar antes de codar

- [ ]
- [ ]

## Formato obrigatório para atualizar um item

```markdown
### APP-XXX — Título

- **Status:** CONFIRMADO | REPRODUZIDO | EM CORREÇÃO | RESOLVIDO | DESATUALIZADO
- **Data da verificação:** YYYY-MM-DD
- **Evidência:** comando, teste, device, log ou caminho exato
- **Causa:** somente após diagnóstico
- **Mudança:** arquivos e resumo curto
- **Verificação:** comandos/testes e resultado
- **Limitações:** o que não foi possível verificar
- **Próximo passo:** apenas se ainda houver trabalho
```

## Critério de qualidade do backlog

Um item só pode sair daqui quando houver:

- comportamento esperado claro;
- escopo e plataforma definidos;
- arquivos/testes identificados;
- evidência atual, não apenas uma anotação antiga;
- verificação executada;
- decisão explícita quando houver trade-off de produto.
