# Wiki: EPUB to MP3

Leitura de EPUB e conversão em audiobook nos clientes Apple nativo, Flutter e
navegador, com comportamento compartilhado em Rust. Formatos e provedores variam
por adaptador; metas de produto e código legado não comprovam suporte atual.

- CLI: `crates/converter-cli/`, usando o pipeline Rust embutido.
- Web: React/TypeScript com Rust/WASM e Piper no navegador.
- Apple: UIKit/AppKit nativos com `converter-ffi` embutido.
- Linux/Windows/Android: Flutter com adaptadores Rust registrados.
- API hospedada de compatibilidade: implantação separada de `converter-server`.

Piper `pt_BR-faber-medium` é o primário. TTS instalado do sistema é o fallback
padrão quando disponível, preferindo Luciana da Apple para português brasileiro.
Escolhas explícitas do job prevalecem. Edge exige consentimento; instalar modelos
exige ação explícita. Voz nativa do navegador serve para escuta; exportar MP3 exige Piper.

## Páginas

- [Primeiros passos](Getting-Started.md)
- [CLI e Web](CLI-and-Web.md)
- [Desktop, Mobile e Releases](Desktop-Mobile-and-Releases.md)
- [Arquitetura](Architecture.md)
- [Configuração e Performance](Configuration-and-Performance.md)
- [Deploy e Hugging Face Spaces](Deployment-and-HF-Spaces.md)
- [Troubleshooting](Troubleshooting.md)
- [Contribuição e Segurança](Contributing-and-Security.md)

Python/FastAPI, notas das antigas slices SwiftUI e guias de sidecar são referências
de migração. Comportamento atual exige inspeção do adaptador e evidência real.
Esta revisão é local; não publica a wiki nem valida um serviço.
