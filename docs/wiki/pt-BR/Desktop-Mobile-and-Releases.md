# Desktop, mobile e releases

Clientes Apple usam UIKit/AppKit nativos com FFI Rust embutida. Comece pelo
[guia Apple](../../../ios/EpubToMp3/README.md) e pela
[validação macOS](../../agents/macos-validation.md). A tarefa completa `mac:build`
compila pré-requisitos FFI; `sidecar:build` é tarefa de servidor independente,
não dependência do aplicativo Apple.

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
