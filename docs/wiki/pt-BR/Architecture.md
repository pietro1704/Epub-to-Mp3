# Arquitetura

Conversão compartilhada pertence a `crates/converter-core/`: parsing, estrutura/
texto, política de provedores/modelos, progresso, cancelamento, persistência e
artefatos. `converter-ffi` expõe a ABI C nativa; `converter-cli` é entrada direta;
`converter-wasm` expõe bindings do navegador. Dependências nativas têm compilação
condicional; processos e rede nativos não formam uma API do navegador.

| Superfície | Entrada no código | Responsabilidade do adaptador |
| --- | --- | --- |
| Apple | `ios/EpubToMp3/EpubToMp3/Features/` | UIKit/AppKit, arquivos locais, mídia e FFI |
| Web | `web/src/services/BrowserConversionClient.ts` | I/O, Piper e armazenamento do navegador em torno de sessões Rust |
| Flutter | `flutter_app/lib/main.dart`, `lib/services/embedded_converter.dart` | Canal nativo Android e FFI Linux/Windows registrados |
| Servidor opcional | `crates/converter-server/src/main.rs` | Contrato HTTP hospedado de compatibilidade |
| Legado | `python_app/`, `hf_app.py` | Fixtures de compatibilidade e referência de migração |

Apple não exige Python ou sidecar HTTP para conversão embutida. A conversão do
navegador não deve selecionar silenciosamente o adaptador HTTP retido. Flutter
registra conversores embutidos; bridges/assets Python retidos não comprovam uso
em produção. Verifique os chamadores antes de remover material legado.

Paths, schemas e persistência dependem do adaptador e da configuração; os antigos
padrões Python `.jobs/`/`.uploads/` não são paths universais das plataformas.
Consulte [navegação do runtime](../../agents/runtime-navigation.md),
[CONTEXT.md](../../../CONTEXT.md) e ADRs relevantes para detalhes.
Código conectado não comprova migração concluída ou aceite em runtime.
