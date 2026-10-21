# Contribuição e segurança

Leia [AGENTS.md](../../../AGENTS.md),
[fluxo de entrega](../../agent-workflow.md),
[política de execução](../../agents/execution-policy.md) e
[padrões de código](../../../CODING_STANDARDS.md). Código, comentários, logs e
documentação técnica ficam em inglês, exceto recursos/páginas da wiki localizados
intencionalmente. Use `CONTEXT.md` e ADRs relevantes; inspecione tarefas mise reais.

Use uma branch/PR por mudança coerente, preserve trabalho alheio, acrescente
regressão significativa e valide proporcionalmente no runtime dono. Erros,
cancelamento e identidade livro/capítulo relevantes importam mais que quantidade
fixa de camadas de teste ou especialistas. Documentação exige checagem de conteúdo/
links. Python/Ruff ficam na CI; web começa com até dois workers; guards nativos,
responsabilidade de plataformas e quarentena do Simulator continuam valendo.

Commit/push e escrita de PR seguem autorização de entrega do escopo verificado.
PRs prontos para `master` mantêm autorização de automerge com `PR gate` do head
exato, base atual e helper confiável; preserve o workflow de merge. Monitoramento
de CI é opt-in. Informe PR, commit, checks/CI observados e aceite pendente com
precisão. Releases, publicação externa e fechar issues têm limites próprios.

Relatos de segurança seguem [SECURITY.md](../../../SECURITY.md): use canal privado,
sem issue pública de vulnerabilidade, com impacto, reprodução e versões afetadas.
Essa política define escopo e suporte atuais; a wiki não redefine exclusões nem
afirma todos os alertas resolvidos. Preserve credenciais/dados privados e não os
publique em fixtures, logs ou relatórios.
