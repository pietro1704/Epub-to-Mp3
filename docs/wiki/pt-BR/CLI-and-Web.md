# CLI e Web

A CLI do produto é Rust (`crates/converter-cli/`). A tarefa `convert` da raiz chama
`scripts/package_rust_cli.rb --run --`, que compila/empacota runtime nativo e assets
de fonemização antes de executar a CLI. Não é atalho somente de leitura para help;
inspecione pré-requisitos e política de build protegido antes de usar.

Para conversão autorizada com pré-requisitos existentes:

```sh
mise run convert -- livro.epub
mise run convert -- livro.epub --chapter position:2
mise run convert -- livro.epub --show-structure
```

Os exemplos seguem o código atual da tarefa/parser; não são evidência de execução.
A CLI converte e inspeciona (`--show-structure`) EPUB e PDF com camada de texto
pelo mesmo despacho de fontes; um PDF sem texto extraível falha antes de iniciar
o job. Veja o [contrato PDF](../../pdf-conversion.md). Use flags `--chapter` repetidas para vários IDs literais;
`position:N` seleciona explicitamente uma posição baseada em zero.
Consulte parser/help para batch,
saída, verificação e preferências, sem presumir suporte a todos os formatos
desejados pelo produto.

Piper `pt_BR-faber-medium` é primário; seleção explícita por job prevalece sobre
preferências salvas. Fallback Edge online exige consentimento explícito. Instalar
modelos é ação explícita separada. Limpar cache é destrutivo e não faz parte do
primeiro uso de conversão.

O cliente web normal é o cliente Rails com Rust/WASM embutido e Piper no
navegador; a conversão roda no navegador. Siga o
[README do web Rails](../../../ruby_app/rails_gateway/README.md) para a árvore de
runtime gerada (`mise run rails:web:runtime-build`) e os testes
(`mise run rails:web:test`).
Voz nativa do navegador serve para escuta; exportar MP3 exige Piper instalado.
Inspecionar EPUB não comprova suporte a PDF ou outros formatos nativos.

`mise run dev` inicia o cliente web Rails na porta 3000 (`WEB_PORT`, `WEB_HOST`); instala as gems que faltam,
prepara o banco de desenvolvimento e avisa quando o runtime do navegador não foi gerado
(`mise run rails:web:runtime-build`). `DEV_RUST_SERVER=1` também inicia o `converter-server` Rust
opcional (o que o compila) e aponta o app Rails para ele por `RUST_CONVERTER_URL`.
`converter-server` e o cliente HTTP retido são adaptadores de compatibilidade;
rotas/payloads pertencem ao código atual do servidor Rust e cliente escolhido.
