# CLI e Web

A CLI do produto é Rust (`crates/converter-cli/`). A tarefa `convert` da raiz chama
`scripts/package_rust_cli.rb --run --`, que compila/empacota runtime nativo e assets
de fonemização antes de executar a CLI. Não é atalho somente de leitura para help;
inspecione pré-requisitos e política de build protegido antes de usar.

Para conversão autorizada com pré-requisitos existentes:

```sh
mise run convert -- livro.epub
mise run convert -- livro.epub --chapter 3
mise run convert -- livro.epub --show-structure
```

Os exemplos seguem o código atual da tarefa/parser; não são evidência de execução.
O help atual da CLI rejeita ingestão de PDF. Consulte parser/help para batch,
saída, verificação e preferências, sem copiar flags Python ou presumir suporte a
todos os formatos desejados pelo produto.

Piper `pt_BR-faber-medium` é primário; seleção explícita por job prevalece sobre
preferências salvas. Fallback Edge online exige consentimento explícito. Instalar
modelos é ação explícita separada. Limpar cache é destrutivo e não faz parte do
primeiro uso de conversão.

O cliente web normal usa Rust/WASM embutido com Piper no navegador. Siga
[web/README.md](../../../web/README.md) para Vite e verificações focadas.
Voz nativa do navegador serve para escuta; exportar MP3 exige Piper instalado.
Inspecionar EPUB não comprova suporte a PDF ou outros formatos nativos.

`mise run dev` inicia servidor Rust opcional e Vite, pode compilar/instalar
pré-requisitos ausentes e gerencia processos de desenvolvimento. Use somente para
jornada de servidor explícita após inspecionar `scripts/dev.sh` e o escopo.
`converter-server` e o cliente HTTP retido são adaptadores de compatibilidade;
rotas/payloads pertencem ao código atual do servidor Rust e cliente escolhido.
Receitas Python/FastAPI e `hf_app.py` são legado, não a inicialização padrão.
