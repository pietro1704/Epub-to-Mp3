# Análise de performance da conversão CLI — The Lord of the Rings

Data da coleta: 23/07/2026, durante a conversão ativa.

## Escopo

Esta análise usa exclusivamente a conversão CLI em andamento e os artefatos que ela já produziu. Nenhum processo foi interrompido e nenhum arquivo da conversão foi alterado.

Processo observado:

- Comando: `./convert ~/Downloads/Ebooks/The Lord of the Rings (...).epub --engine auto --verbose`
- PID do Python: `8310`
- Engine efetivamente observada: Edge-TTS
- Total de capítulos informado pelo cache: 95
- Logs: `.logs/events.jsonl`
- Métricas runtime: `.cache/The Lord of the Rings/_runtime_metrics.jsonl`
- Chunks de streaming: `.cache/The Lord of the Rings/streams/cli/`

O registro final de `.logs/conversions.jsonl` ainda não existia para esta execução porque a conversão continuava em andamento.

## Resumo executivo

O gargalo dominante é rede/Edge-TTS, não CPU, RAM do processo ou disco:

1. A amostra do processo ficou principalmente aguardando o event loop (`kevent`) e recebendo dados por socket/SSL.
2. O conversor utilizou apenas cerca de 1–3% de CPU e aproximadamente 30–36 MiB de RSS.
3. A velocidade ponderada observada foi de aproximadamente 226,6 caracteres/s.
4. Foram produzidos 962 chunks para 1,22 milhão de caracteres. A média foi de aproximadamente 1.267 caracteres por request, o que gera muitas conexões/round-trips para um serviço WebSocket externo.
5. O paralelismo de capítulos está funcionando: média estimada de 3,73 capítulos simultâneos e pico de 8 no intervalo observado. Portanto, o problema não é simplesmente “o CLI está serial”.
6. O pipeline de preparação aparece como habilitado, mas cada worker paralelo recebe uma lista de um único capítulo. Isso limita o benefício do pipeline entre preparação e síntese.
7. A telemetria atual não registra a latência de cada request Edge, tempo de fila, status HTTP, retries ou concorrência efetiva por request. Isso dificulta medir a causa exata da variabilidade.

## Evidências coletadas

### Conversor e host

- Tempo de execução observado: aproximadamente 37 minutos na última verificação.
- Host: 8 CPUs lógicas, 4 CPUs físicas, 8 GiB de RAM.
- RAM disponível durante a coleta do perfil: aproximadamente 1,58 GiB.
- Rede detectada pelo probe: `ultra`.
- Perfil de hardware: `high`, com paralelismo recomendado.
- Espaço livre no volume de dados: aproximadamente 43 GiB.
- Tamanho de `.cache`: aproximadamente 867 MiB.
- Tamanho de `output`: aproximadamente 732 KiB no momento da coleta, pois a execução ainda estava trabalhando nos artefatos de streaming/cache.

A baixa utilização do processo e a conexão TCP ativa com um endpoint Microsoft na porta 443 indicam espera por serviço/rede. O `sample` de 5 segundos mostrou principalmente:

- `kevent` no event loop do Python;
- `sock_recv_into`/`recvfrom`;
- leitura SSL (`SSL_read`);
- pouca atividade de CPU propriamente dita.

### Throughput por capítulo

No intervalo de 14:30:03 a 14:52:54 foram observados 35 eventos `chapter_perf`:

- caracteres sintetizados: 1.156.904;
- soma dos tempos individuais: 5.106,3 s;
- velocidade ponderada: 226,6 caracteres/s;
- mediana por capítulo: 220,0 caracteres/s;
- mínimo: 4,0 caracteres/s, correspondente a capítulo praticamente vazio;
- máximo: 302,9 caracteres/s;
- duração de parede do intervalo: 1.370,7 s;
- sobreposição máxima calculada: 8 capítulos;
- sobreposição média calculada: 3,73 capítulos.

Exemplos recentes:

| Capítulo | Caracteres | Chunks | Tempo | Velocidade |
|---|---:|---:|---:|---:|
| 10.1.1 | 18.004 | 14 | 71,6 s | 252,7 c/s |
| 10.1.2 | 58.625 | 47 | 271,4 s | 216,2 c/s |
| 10.1.3 | 41.761 | 34 | 185,9 s | 225,1 c/s |
| 10.1.4 | 65.312 | 52 | em andamento/concluído no snapshot | — |

As diferenças entre capítulos do mesmo livro são compatíveis com variação de latência e geração do Edge, não com saturação do processador local.

## Gargalos priorizados

### P0 — Latência e throughput do Edge-TTS

**Status: comprovado.**

A execução depende de uma conexão externa por request e o processo passa a maior parte do tempo aguardando I/O. A velocidade observada de aproximadamente 226,6 caracteres/s é o limite atual de throughput da cadeia Edge + rede + controle de concorrência.

O código já usa paralelismo em lotes (`python_app/src/tts/edge_engine.py:948-961` e `1257-1440`), mas cada request ainda depende da abertura/uso do transporte Edge e da resposta do serviço. O próprio módulo documenta que o Edge usa um WebSocket novo por request e que concorrência excessiva pode causar bloqueios 403.

**Melhoria recomendada:** otimizar e medir o transporte antes de aumentar agressivamente a concorrência:

- registrar latência de fila, conexão, primeiro byte, último byte e gravação do MP3 por chunk;
- registrar status/erro do request, retries e motivo do retry;
- manter aumento gradual de concorrência e redução multiplicativa ao detectar 403, timeout ou `no_audio`;
- avaliar pooling/reuso de transporte somente se for compatível com a biblioteca Edge-TTS usada;
- comparar configurações 4, 6 e 8 em um benchmark controlado, sem assumir que 16 será mais rápido.

### P0 — Requests pequenos demais

**Status: comprovado como oportunidade de redução de overhead.**

Foram observados 962 chunks para aproximadamente 1.218.626 caracteres nos manifests recentes, média de 1.266,8 caracteres por chunk e 26,7 chunks por capítulo.

Esse tamanho médio é muito inferior ao limite configurado de chunk e aumenta:

- número de requests WebSocket/TLS;
- número de esperas de resposta;
- número de arquivos temporários;
- número de callbacks e atualizações do manifest;
- custo de validação por segmento.

A segmentação atual é influenciada pelo limite de duração (`EDGE_MAX_SEGMENT_SECONDS`) e pela divisão de texto em segmentos, não apenas por `EDGE_CHUNK_CHARS`. O código define 85 s como padrão no `ConversionConfig` e no engine (`python_app/src/config.py:64-75` e `python_app/src/tts/edge_engine.py:43-60`).

**Melhoria recomendada:** criar um perfil de throughput adaptativo:

1. iniciar em 85–120 s;
2. aumentar gradualmente para 120–180 s em capítulos limpos, sem falhas ou truncamentos;
3. voltar automaticamente para 45–85 s quando houver `no_audio`, timeout, áudio incompleto ou aumento do p95;
4. preservar o retry seguro com segmentos menores.

O aumento não deve ser aplicado cegamente: o módulo registra histórico de problemas em segmentos muito grandes. A decisão precisa ser validada por benchmark de qualidade e integridade.

### P0 — Telemetria insuficiente para localizar o custo por request

**Status: comprovado.**

Os logs atuais registram principalmente métricas agregadas por capítulo (`chapter_perf`) e estágios `prepare`/`synthesize`. Eles não permitem responder diretamente:

- quanto tempo cada request ficou aguardando semaphore;
- quanto tempo foi gasto conectando ao Edge;
- qual foi a latência de geração do serviço;
- quantos requests foram retried sem gerar um capítulo falho;
- qual era a concorrência real no instante de cada request;
- quanto tempo foi gasto gravando/validando cada chunk.

**Melhoria recomendada:** adicionar uma métrica compacta por segmento, sem armazenar o texto completo:

```text
chapter_id, segment_id, chars, engine, queue_wait_ms,
request_ms, write_ms, validation_ms, status, retry_count,
active_requests, chunk_chars, error_category
```

Com isso será possível otimizar com dados reais, em vez de inferir o gargalo apenas pelo `chars_per_second` do capítulo.

### P1 — Preparação global antes da primeira síntese

**Status: provável e mensurável.**

O processo iniciou por volta de 14:20 e o primeiro evento `chapter_perf` observado ocorreu por volta de 14:30. Isso deixa um intervalo de aproximadamente 10 minutos antes da primeira métrica de síntese.

O caminho atual gera os arquivos de texto para todos os capítulos antes de iniciar a conversão TTS (`python_app/src/converter.py:2154-2161`). Essa estratégia evita reprocessamento, mas aumenta o tempo até o primeiro áudio e não aproveita o streaming do pipeline.

**Melhoria recomendada:** usar preparação preguiçosa e limitada:

- preparar os primeiros capítulos imediatamente;
- manter uma fila de preparação com profundidade pequena, por exemplo 2–8 capítulos;
- iniciar TTS assim que houver payload válido;
- continuar a preparação em paralelo;
- persistir o cache de texto em segundo plano.

O pipeline atual é criado dentro do worker de síntese (`converter.py:3778-3824`). Já o paralelismo de capítulos chama `_convert_chapters_sequential([chapter], ...)` para cada worker (`converter.py:3151-3163`). Por isso, os eventos mostram repetidamente `pipeline_enabled` com `chapters: 1`: a profundidade 8 não representa oito capítulos preparados por uma fila global.

### P1 — Turbo mode agressivo para uma máquina com pouca RAM disponível

**Status: risco de eficiência/estabilidade, não gargalo comprovado nesta coleta.**

O hardware detector classificou a rede como `ultra` e o perfil como `high`, mas havia apenas aproximadamente 1,58 GiB de RAM disponível. O `HardwareDetector.apply_optimizations()` mantém `MAX_PERFORMANCE` ativo por padrão e pode elevar o paralelismo para 8 capítulos e a concorrência Edge para valores altos (`python_app/src/hardware_detector.py:585-648`).

A execução atingiu pico de 8 capítulos simultâneos, mas a média efetiva ficou em 3,73. Isso indica que aumentar o teto automaticamente pode não gerar ganho linear e pode aumentar:

- pressão de memória;
- contenção de arquivos temporários;
- probabilidade de 403/rate limit;
- variação de latência;
- tempo gasto em retries.

**Melhoria recomendada:** trocar o teto fixo de turbo por controle de pressão:

- reduzir slots quando RAM disponível ficar abaixo de um limite;
- aumentar somente quando p95 de latência e taxa de erro permanecerem estáveis;
- registrar o motivo de cada mudança de slots;
- tratar a concorrência de capítulos e a concorrência de chunks como orçamentos separados;
- validar se 4 ou 6 slots produzem melhor throughput efetivo que 8 no Mac atual.

Não é recomendável simplesmente remover o limite de 8 sem benchmark, pois o próprio engine documenta risco de 403 acima desse patamar.

### P1 — Validação por segmento e I/O de streaming

**Status: custo provável; magnitude ainda não medida.**

O caminho paralelo chama `AudioValidator.get_audio_duration()` para segmentos bem-sucedidos (`edge_engine.py:1535-1547`). O validator usa Mutagen para ler cada MP3 (`python_app/src/audio_validator.py:58-99`). Além disso, o modo streaming mantém um arquivo MP3 por chunk, atualiza manifests e depois concatena os arquivos.

Para aproximadamente 962 chunks recentes, isso representa centenas de leituras de metadados e operações de filesystem adicionais. Não há evidência de que esse seja o gargalo dominante — a amostra aponta para rede —, mas ele pode reduzir o throughput quando o Edge estiver rápido.

**Melhoria recomendada:** separar modos de validação:

- caminho rápido durante síntese: existência, tamanho mínimo e integridade básica;
- validação completa de duração no nível do capítulo;
- validação profunda somente para capítulos suspeitos ou após falha;
- manter o retry seletivo para segmentos inválidos.

A validação não deve ser removida globalmente; deve ser deslocada para o ponto que maximiza custo/benefício.

### P2 — Crescimento e duplicação do cache de streaming

**Status: observado, não dominante no momento.**

O cache tinha aproximadamente 867 MiB e o volume ainda possuía cerca de 43 GiB livres. Os chunks são úteis para retomada, mas ficam lado a lado com o MP3 concatenado e os manifests.

**Melhoria recomendada:** após a finalização e validação do capítulo:

- manter apenas o MP3 final por padrão;
- preservar chunks somente quando a política de resume exigir;
- compactar ou mover chunks antigos para uma área de recuperação;
- registrar bytes temporários e tempo de limpeza.

A limpeza precisa continuar protegendo capítulos ativos e permitir retomada após interrupção.

### P2 — Telemetria de capítulo está identificando capítulos de forma ambígua

**Status: comprovado.**

Muitos eventos recentes `chapter_perf` aparecem com `chapter_index: 1`, embora os nomes sejam capítulos diferentes como `9.1.1`, `9.2.2` e `10.1.2`. Os manifests também exibem `chapterIndex: 1` para vários diretórios.

A causa provável é a execução de cada worker com uma lista de um capítulo e uso do índice local `idx + 1`. O código tenta preservar o índice original, mas o caminho de logging ainda não mantém uma identidade estável em todos os eventos.

**Melhoria recomendada:** separar explicitamente:

- `source_chapter_index`: índice original no EPUB;
- `display_chapter_label`: rótulo hierárquico, por exemplo `10.1.3`;
- `worker_local_index`: índice local dentro do worker;
- `segment_index`: posição do chunk.

Isso melhora ETA, análise de cauda, cache hit/miss e comparação de capítulos sem alterar o áudio produzido.

## O que não aparece como gargalo principal

- CPU: o processo ficou em torno de 1–3%.
- Memória do processo: aproximadamente 30–36 MiB de RSS; a amostra registrou footprint físico de aproximadamente 180 MiB.
- Disco: há espaço livre suficiente e a atividade observada não indica saturação de I/O do host.
- Fallback: os 35 capítulos recentes foram concluídos com Edge e `attempt: 1`; não há evidência de que Piper ou retries estejam consumindo o tempo atual.
- Preparação por capítulo: os eventos `pipeline_stage_done` de `prepare` ficaram na ordem de milissegundos nos workers já preparados; o custo aparente está no preparo inicial/global, não nesses pequenos estágios individuais.

## Plano de melhoria recomendado

### Fase 1 — Medir sem alterar comportamento

1. Adicionar métricas por request/segmento.
2. Registrar a configuração efetiva no início da execução: slots de capítulo, concorrência Edge, chunk chars, duração máxima, modo turbo e tier de rede.
3. Corrigir a identidade dos capítulos nos logs.
4. Registrar separadamente tempo de síntese, concatenação, validação e escrita do manifest.

### Fase 2 — Benchmark controlado

Executar o mesmo conjunto de capítulos representativos em três perfis:

- concorrência de capítulos: 4, 6 e 8;
- duração de segmento: 85, 120 e 180 s;
- mesma voz, mesmo livro e mesma rede;
- sem misturar resultados de cache com síntese nova.

Métricas de aceitação:

- tempo total de parede;
- caracteres/s efetivos;
- p50 e p95 de latência por request;
- requests por milhão de caracteres;
- taxa de 403, timeout, `no_audio` e retry;
- pico de RAM e pressão do sistema;
- capítulos/segmentos incompletos;
- tamanho final de cache.

### Fase 3 — Otimizar a arquitetura

1. Implementar preparação global limitada e início antecipado da síntese.
2. Adotar segmentação adaptativa com rollback automático.
3. Separar validação rápida de validação completa.
4. Ajustar slots com base em throughput e pressão real, não apenas no probe inicial.
5. Limpar ou compactar chunks depois da confirmação do MP3 final.

## Conclusão

A maior oportunidade de velocidade está no caminho Edge-TTS: reduzir o custo por request, medir a latência real e manter a maior concorrência que não aumente retries ou rate limits. A execução atual já usa paralelismo de capítulos, mas o ganho é limitado por aproximadamente 226,6 caracteres/s por capítulo e por quase mil chunks recentes.

O segundo ponto mais importante é o tempo até o primeiro áudio: a preparação global antes do TTS parece consumir cerca de 10 minutos e o pipeline configurado não está globalmente sobreposto entre preparação e síntese.

Antes de alterar defaults, a prioridade correta é instrumentar request-level timing e executar um A/B pequeno. Isso evita trocar um gargalo de rede por 403, pressão de RAM ou reconversões causadas por validação insuficiente.
