# Configuração e performance

Política de provedores/modelos pertence a preferências, catálogo e runtime Rust
compartilhados e ao adaptador escolhido. Piper `pt_BR-faber-medium` é primário.
TTS nativo instalado é o fallback padrão quando disponível, preferindo Luciana
para pt-BR na Apple. Informe backend/voz ativos; mantenha Piper primário e tente
recuperá-lo em pontos limitados. Seleções explícitas do job prevalecem. Edge é opt-in.

Instalar modelos exige ação explícita e preserva os existentes. Voz nativa do
navegador permite escuta, mas não produz MP3; exportação exige Piper no navegador.
Amostra estática ou catálogo legado não comprova disponibilidade de modelo.

Inspecione `crates/converter-core/src/config.rs`, `paths.rs`, `tts_preferences.rs`,
módulos de modelo/runtime e configurações do cliente antes de citar variáveis de
ambiente ou paths persistentes. Overrides Python antigos de concorrência Edge não
são perfil universal atual. Preferência salva, escolha do job e ambiente podem ter
precedências distintas; teste a interface afetada.

Cache é estado do runtime: preserve livros, modelos e artefatos utilizáveis.
Evite limpeza ou rebuild amplo sem escopo. Build no Mac usa lease compartilhado,
um job e política de armazenamento; testes web começam com até dois workers.
Limites e volumes persistentes hospedados exigem verificação da implantação.

Alegações de desempenho exigem identidade comparável de código/toolchain/modelo/
entrada, medições antes/depois e limites conhecidos. Número de campanha histórica
não comprova velocidade atual nem autoriza benchmark novo. Leia a
[política de execução](../../agents/execution-policy.md) antes de trabalho pesado.
