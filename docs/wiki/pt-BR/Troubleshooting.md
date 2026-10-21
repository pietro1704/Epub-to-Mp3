# Troubleshooting

Identifique adaptador, revisão e artefato antes de escolher diagnóstico. Preserve
erro/log original e use a menor verificação na interface afetada. Consulte a
[política de execução](../../agents/execution-policy.md) para limites e plataformas.

- Navegador: inspecione exports WASM, assets TTS, suporte de armazenamento e estado
  da instalação/checksum do modelo. Modelo ausente não autoriza download ou troca
  para HTTP/Edge. Voz nativa do navegador não exporta MP3.
- Apple: inspecione FFI/ONNX embutidos, arquitetura/plataforma e assinaturas;
  use inspeção/empacotamento de `mac:validate` antes de rebuild justificado. Siga
  logs nativos e receipt exato em vez de procurar sidecar Python.
- Flutter: confira adaptador Android/desktop registrado e identidade da biblioteca
  nativa empacotada. Mantenha Android pausado e trabalho autorizado dessa plataforma no Arch.
- Servidor opcional: inspecione revisão Rust/container, porta, paths e logs.
  Dependências Python legadas não são o diagnóstico padrão do produto.

Informe fallback/voz ativos e preferências explícitas do job quando Piper falhar.
Mantenha Piper primário e recuperação limitada conforme política compartilhada.
Não inicie benchmark, instalação de modelos ou limpeza de cache como correção inferida.

Limites de upload e erros HTTP pertencem ao adaptador/servidor selecionado;
confirme configuração atual antes de sugerir overrides antigos. Para segurança,
reproduza com cuidado, inspecione confinamento/sanitização e siga
[SECURITY.md](../../../SECURITY.md). Dismiss de alertas e fechamento de issues
exigem autorização aplicável e evidência.

Simulator está em quarentena; aceite SE1/iOS 15.5 segue pendente. Kernel panic novo
exige parada conforme a política. Não tente outro launcher, reinicie serviço/host
ou altere runtime/hardware para contornar uma falha.
