# Uso de IA no desenvolvimento — lições aplicáveis ao Epub-to-Mp3

Data: 17/08/2026
Escopo: síntese prática de textos e vídeos publicados pelo próprio Fábio Akita, adaptada ao fluxo deste repositório. As recomendações abaixo são decisões operacionais propostas para este projeto, não afirmações de que Akita prescreveu cada detalhe dele.

## Síntese executiva

IA deve ser tratada como par de programação veloz, não como autora autônoma de mudanças. O ganho sustentável vem de: contexto de projeto curto e recuperável; pedido com objetivo, limites e evidência de pronto; ciclos pequenos de implementação e verificação; testes/CI como feedback; e refatoração contínua para manter o código navegável por agentes.

O repositório já possui boa parte da base: `AGENTS.md`, memória operacional, comandos previsíveis via `mise`, testes separados por superfície e pipeline de entrega. As melhorias propostas são usar essas peças de modo consistente e tornar as regras ainda mais fáceis de localizar e executar.

## Princípios e aplicação

### 1. O humano define o problema; o agente propõe e executa o caminho

Fornecer quatro blocos em cada tarefa relevante: **objetivo**, **direção/limites**, **o que não pode mudar** e **como provar que terminou**. Depois que o contexto estiver estabelecido, pedir alternativas com trade-offs em vez de ditar a solução linha a linha. Durante execuções longas, acompanhar evidências e interromper caminhos que se afastem do objetivo.

Aplicação aqui:

- Para mudanças na conversão, declarar explicitamente se o escopo é CLI, servidor ou ambos — a arquitetura tem dois caminhos que precisam permanecer equivalentes.
- Para mudanças Apple, declarar plataforma, comportamento observável e método permitido de validação; nunca supor que um build de simulator é aceitável nesta máquina.
- Toda solicitação de implementação deve nomear a verificação: teste unitário/integrado, `mise run test`, build aplicável ou validação em dispositivo.

Fontes: [Why LLMs Aren't Giving You the Result You Expect](https://akitaonrails.com/en/2026/04/15/how-to-talk-to-claude-code-effectively/), [From Zero to Post-Production in 1 Week](https://akitaonrails.com/en/2026/02/20/zero-to-post-production-in-1-week-using-ai-on-real-projects-behind-the-m-akita-chronicles/).

### 2. Preservar contexto como artefato versionado, não só no chat

Agentes perdem detalhes com compactação e troca de sessão. Registrar decisões, armadilhas verificadas, fontes e próximos passos em Markdown por tópico; manter um índice curto apontando para esses documentos. Memória deve ser texto portátil, revisável e atualizada quando a realidade do projeto mudar.

Aplicação aqui:

- `docs/codex-working-memory.md` e as regras do repositório devem apontar para este documento como guia de fluxo de IA.
- Criar notas específicas em `docs/` para decisões duráveis; evitar transformar a memória principal em um diário longo.
- Quando uma investigação revelar uma exceção operacional (por exemplo, um limite do Edge-TTS ou uma restrição de dispositivo), registrar o **porquê**, a evidência e o caminho de validação.

Fonte: [AI Agent Memory: Karpathy LLM Wiki and agentmemory in Practice](https://akitaonrails.com/en/2026/05/18/ai-agent-memory-karpathy-llm-wiki-agentmemory/).

### 3. Projetar código e documentação para navegação por agente

Arquivos e funções pequenos, uma responsabilidade por módulo, nomes específicos que retornem poucos resultados em `rg`, estrutura previsível e tipos explícitos reduzem contexto, custo e risco de alteração incompleta. Comentários devem preservar intenção, origem de workarounds e restrições — nunca narrar sintaxe óbvia.

Aplicação aqui:

- Manter a decomposição atual de `converter.py` por mixins e de `server.py` por helpers; extrair responsabilidade antes de uma mudança tornar um módulo difícil de carregar de uma vez.
- Preferir nomes que expressem o domínio (`edge_chapter_timeouts`, `apply_structural_speech_cues`) a abstrações genéricas (`data`, `handler`, `manager`).
- Ao adicionar uma exceção, documentar a causa e o teste/regressão que a justifica; atualizar a nota quando o workaround deixar de existir.
- Preferir contratos tipados no Python e TypeScript sempre que uma forma de dado não for autoevidente.

Fonte: [Clean Code for AI Agents](https://akitaonrails.com/en/2026/04/20/clean-code-for-ai-agents/).

### 4. Fechar o loop: teste executável, CI e commits pequenos

O agente produz código plausível com rapidez; sem uma verificação automatizada executável ele fica "cego". Trabalhar em mudanças pequenas, com teste de regressão quando aplicável, CI em cada commit e refatorações frequentes impede a acumulação de dívida que reduz a velocidade futura.

Aplicação aqui:

- Mudanças Python/web: seguir a política existente de teste adjacente e executar `mise run test` antes de commit.
- Mudanças Swift: adicionar XCTest no target adequado e entregar o comando/validação para o dispositivo ou CI permitido; não criar teste Python que apenas leia fonte Swift.
- Não misturar refatoração ampla com mudança de comportamento sem uma razão clara; manter commits reversíveis e prontos para integração.
- Tratar segurança e performance como gates contínuos: vulnerabilidade, regressão ou degradação mensurável interrompe a sequência normal até ser resolvida.

Fontes: [Clean Code for AI Agents](https://akitaonrails.com/en/2026/04/20/clean-code-for-ai-agents/), [From Zero to Post-Production in 1 Week](https://akitaonrails.com/en/2026/02/20/zero-to-post-production-in-1-week-using-ai-on-real-projects-behind-the-m-akita-chronicles/).

### 5. Delegar apenas trabalho realmente independente

Subagentes têm custo de especificação, revisão e reintegração. Usá-los para investigação, revisão ou implementação com fronteira clara e arquivos/responsabilidades predefinidos; manter no agente principal mudanças que exigem decisão arquitetural ou contexto transversal intenso.

Aplicação aqui:

- Delegar em paralelo apenas pesquisa, auditoria ou módulos sem sobreposição de arquivos.
- Atribuir ownership explícito e pedir evidências/finalização objetiva ao delegar.
- Para uma alteração pequena ou fortemente acoplada entre CLI, servidor e cache, manter um fluxo único para evitar perda de contexto e divergência entre os dois pipelines.

Fonte: [LLM Benchmarks Parte 2: Vale Combinar Múltiplos Modelos no Mesmo Projeto?](https://akitaonrails.com/2026/04/18/llm-benchmarks-parte-2-multiplos-modelos/).

### 6. Fazer experimentos descartáveis e decidir com números

Para comparar modelo, biblioteca, arquitetura ou parâmetro, isolar uma experiência reversível e registrar hipótese, custo, latência, qualidade, resultado e recomendação. Implementar primeiro o menor fluxo funcional; só extrair uma abstração quando repetição real ou uma métrica justificar. Remover artefatos de experimento que não se tornam produto.

Aplicação aqui:

- Benchmarks de Edge-TTS/Piper devem usar livros e cenários representativos, medir throughput e integridade do áudio, e preservar a configuração vencedora junto da evidência.
- Não expandir a arquitetura de conversão antes de comprovar que um padrão se repete em ambos os pipelines.
- Tratar protótipos como protótipos: marcar seu escopo e não promovê-los sem os gates de qualidade da superfície de produção.

Fontes: [AI Memory: arquitetura emergente e software maleável](https://akitaonrails.com/2026/06/14/ai-memory-arquitetura-emergente-e-software-maleavel/), [Terminando a Maratona IA: Sucesso ou Fracasso?](https://akitaonrails.com/2026/05/14/terminando-maratona-ia-sucesso-ou-fracasso/).

### 7. Usar autonomia proporcional ao risco

Sandbox reduz o raio de impacto, mas não substitui revisão. Antes de operações externas ou `push`, conferir arquivos alterados/staged e a ausência de segredos; preservar Git remoto/backups e pedir confirmação quando a ação for irreversível ou ampliar autorização.

Aplicação aqui:

- Manter o sandbox e a política de ações destrutivas já configurados para os agentes.
- Antes de enviar alterações, revisar `git diff`, o escopo efetivo e saídas que possam conter credenciais.
- Nunca converter acesso amplo a máquina, dados do usuário ou serviços externos em permissão implícita de uma tarefa local.

Fonte: [Dicas e Toolkit de IA do Akita: ai-jail, ai-memory, ai-usagebar](https://akitaonrails.com/2026/05/24/dicas-e-toolkit-de-ia-do-akita-ai-jail-ai-memory-ai-usagebar/).

### 8. Usar vídeos de IA como demonstrações críticas, não como prova de produção

No vídeo experimental Akitando #148, Akita relata alucinações, baixa variância e custo/tempo desfavorável de ferramentas generativas de vídeo. A lição para este projeto é generalizável: uma demo impressionante não substitui avaliação de confiabilidade, custo, qualidade e caminho de fallback.

Aplicação aqui:

- Para engines TTS, bibliotecas e automações novas, medir em livro/fluxo representativo antes de promover a padrão.
- Manter fallback, validação de áudio e telemetria; não substituir um fluxo resiliente por uma integração apenas porque funciona em uma demonstração.
- Registrar números antes/depois para qualquer alegação de performance.

Fonte (vídeo/transcrição first-party): [Akitando #148 — O que IAs podem fazer?](https://akitaonrails.com/2023/11/29/akitando-148-o-que-ias-podem-fazer-exemplos-de-ferramentas/).

## Checklist operacional para tarefas com IA

1. Escrever objetivo, escopo, invariantes e evidência de pronto.
2. Ler as regras e a memória/nota diretamente relacionada ao módulo antes de editar.
3. Para trabalho grande, investigar e propor o menor plano verificável; para trabalho pequeno, editar e validar diretamente.
4. Implementar mudanças mínimas e manter CLI/servidor espelhados quando o comportamento for compartilhado.
5. Rodar a verificação definida e uma crítica de regressões de borda.
6. Registrar decisões ou exceções duráveis no documento temático e manter o índice de memória apontando para ele.
7. Antes de integrar: revisar o diff, confirmar que não há mudanças não relacionadas, checar segredos e seguir o gate de CI/push quando autorizado.

## Limites desta pesquisa

As fontes são publicações e vídeos do próprio Akita, úteis como relato de prática e orientação de processo. Elas não substituem evidência específica do Epub-to-Mp3: decisões de arquitetura, segurança, custo e performance deste repositório continuam exigindo testes, benchmarks e revisão local.
