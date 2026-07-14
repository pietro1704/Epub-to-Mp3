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

- Último commit iOS validado no iPhone: `f6706f1 fix(ios): stabilize reader chapter navigation`.
- Correção de retorno ao capítulo anterior confirmada manualmente no iPhone.
- Branch `master` sincronizada com `origin/master`.
- Existem alterações locais não relacionadas à correção anterior; elas devem ser auditadas e separadas antes de qualquer novo commit.
- Destino físico preferencial: iPhone conectado por USB.

## Plano 0 — Higienizar o estado local

**Objetivo:** separar mudanças verificadas, mudanças incompletas e alterações não relacionadas.

- Revisar o diff dos arquivos Swift/localização atualmente modificados.
- Identificar a qual feature cada alteração pertence.
- Criar testes para qualquer mudança iOS que permaneça.
- Commitar apenas mudanças verificadas; preservar o restante sem misturar escopos.

**Saída:** working tree compreensível e cada commit representando uma única decisão.

## Plano 1 — Reader e navegação

**Objetivo:** eliminar inconsistências visíveis e de estado no leitor.

- Auditar a fonte única do índice de capítulo (`ReaderCoordinator`, reader e player).
- Validar TOC do top bar, hyperlinks, notas e seleção explícita contra audio-follow.
- Validar crossing forward/backward, paginação final, safe area, chrome e contadores.
- Reproduzir no iPhone os fluxos críticos após cada correção.

**Critério de saída:** navegação sem flicker, sem capítulo/página incorretos e sem sobrescrita indevida da seleção do usuário.

## Plano 2 — Player, fila e read-along

**Objetivo:** manter áudio, cursor e posição visual coerentes.

- Auditar `AudioPlayer` como ponto central de decisão de play/pause/seek.
- Confirmar que o capítulo corrente representa o item audível, não áudio apenas enfileirado.
- Testar divergência reader ↔ player no mesmo capítulo e entre capítulos.
- Validar streaming, queue append, retomada, stop e fallback sem desmontar fila viva.

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
