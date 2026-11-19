# Primeiros passos

Escolha o cliente primeiro. Leia [Arquitetura](Architecture.md), depois inspecione
`mise.toml`, o manifesto relevante e a
[política de execução](../../agents/execution-policy.md). Versões de ferramentas
pertencem aos manifestos; a instalação não parte de uma lista Python duplicada.

- Apple: siga o [guia nativo](../../../ios/EpubToMp3/README.md) e a
  [validação macOS](../../agents/macos-validation.md), reutilizando artefatos compatíveis.
- Navegador: siga o [README do web Rails](../../../ruby_app/rails_gateway/README.md);
  `mise run rails:web:runtime-build` gera a árvore de runtime Rust/WASM e TTS e
  `mise run rails:web:test` roda os testes. A árvore deve corresponder ao código
  atual; ela nunca é commitada.
- CLI: [CLI e Web](CLI-and-Web.md) descreve a tarefa Rust `convert`.
- Flutter: siga [flutter_app/README.md](../../../flutter_app/README.md) e os
  pré-requisitos da plataforma; trabalho Android está pausado.

Instalar modelos exige ação explícita. Selecione/instale Piper
`pt_BR-faber-medium` pela ação disponível no cliente quando desejado; preserve os
outros modelos. Modelo ausente não autoriza download, Edge ou provedor pago
silencioso. Recursos do navegador e dependências nativas precisam de verificação real.

Existir uma tarefa não comprova instalação, conversão ou release funcionando.
Registre revisão, artefato e resultado observado. A execução do Simulator está
em quarentena. Empacotar, compilar, abrir e validar o
app visível são etapas distintas.
