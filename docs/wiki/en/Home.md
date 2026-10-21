# Wiki: EPUB to MP3

EPUB reading and audiobook conversion across native Apple, Flutter and browser
clients, with shared Rust conversion behavior. Format/provider support varies by
adapter; product targets and retained legacy code do not prove current support.

- CLI: `crates/converter-cli/`, using the embedded Rust pipeline.
- Web: React/TypeScript plus Rust/WASM and browser Piper.
- Apple: native UIKit/AppKit with embedded `converter-ffi`.
- Linux/Windows/Android: Flutter with registered Rust adapters.
- Hosted compatibility API: separate Rust `converter-server` deployment.

Piper `pt_BR-faber-medium` is primary. Installed system TTS is the default fallback
where supported, preferring Apple Luciana for Brazilian Portuguese when available.
Explicit job selections win. Edge requires consent; models require an explicit
installation action. Browser native speech is listening-only; MP3 export needs Piper.

## Pages

- [Getting Started](Getting-Started.md)
- [CLI and Web](CLI-and-Web.md)
- [Desktop, Mobile and Releases](Desktop-Mobile-and-Releases.md)
- [Architecture](Architecture.md)
- [Configuration and Performance](Configuration-and-Performance.md)
- [Deployment and Hugging Face Spaces](Deployment-and-HF-Spaces.md)
- [Troubleshooting](Troubleshooting.md)
- [Contributing and Security](Contributing-and-Security.md)

Legacy Python/FastAPI, SwiftUI slice notes and old sidecar guides are migration
references. Current behavior requires source inspection and evidence from the
actual adapter. This wiki update is local; it does not publish or validate a service.
