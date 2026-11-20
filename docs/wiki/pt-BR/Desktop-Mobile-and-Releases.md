# Desktop, mobile e releases

Clientes Apple usam UIKit/AppKit nativos com FFI Rust embutida. Comece pelo
[guia Apple](../../../ios/EpubToMp3/README.md) e pela
[validação macOS](../../agents/macos-validation.md). A tarefa completa `mac:build`
compila pré-requisitos FFI; o servidor HTTP Rust independente não é dependência
do aplicativo Apple.

Flutter atende Linux/Windows/Android com adaptadores Rust nativos registrados.
Siga o [guia Flutter](../../../flutter_app/README.md); arquivos de compatibilidade
não comprovam requisito de Python do sistema ou servidor remoto. Flutter Linux e
Android/Samsung pertencem ao Arch; Android permanece pausado até retomada.
Empacotar Windows exige toolchain correspondente.

Compilação no Mac usa tarefas protegidas. Execução do Simulator está em quarentena;
aceite obrigatório do leitor no SE1/iOS 15.5 segue pendente e não pode ser trocado
por dispositivo físico ou outro runtime. Build, teste unitário ou registro no
código não comprovam jornada visível do leitor, conversão ou áudio.

Verifique workflows e artefatos de release na revisão exata. Leia
`.github/workflows/release-desktop.yml` e workflows da plataforma sem presumir que
toda tag publica todas as plataformas ou inclui Python. Assinatura, arquitetura,
dependências e assets de modelo exigem evidência do artefato. Criar release/tag,
publicar em loja/TestFlight e fazer deploy exigem autorização separada; atualizar
esta documentação não executa essas ações.

Fluxo de versão e tag: a versão do produto é commitada (`Cargo.toml`, `Cargo.lock`,
`ruby_app/rails_gateway/VERSION`, `CHANGELOG.md`). Depois de um merge validado no
master, `release-pr.yml` calcula a próxima versão pelos Conventional Commits desde a
última tag e abre um pull request `chore(release): vX.Y.Z` (exige o segredo
`RELEASE_PR_TOKEN` e nunca faz merge sozinho; o caminho confiável de merge ou uma
pessoa o mescla). Mesclar esse pull request deixa `auto-release.yml` criar a tag e
uma release do GitHub com notas geradas. Não compila artefatos: `release-desktop.yml`
continua uma execução manual separada para uma tag publicada. Se essa cadeia pode
publicar sem passo humano é decisão do dono.
