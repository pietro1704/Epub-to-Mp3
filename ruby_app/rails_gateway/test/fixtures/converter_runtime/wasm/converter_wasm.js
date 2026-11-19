// TEST FIXTURE. Hand-written stand-in for the wasm-bindgen glue that
// `wasm-bindgen --target web` generates from crates/converter-wasm. It is not
// generated code and performs no conversion: it keeps the entry-point names
// (default init, tts_catalog_json_v2, inspect_epub) so Rails tests can exercise the
// page's runtime loading without a Rust toolchain. Continuous integration runs
// the same tests against the real generated runtime.

let initialised = false
let readerFixtures

// Like the real glue, initialisation fetches the sibling .wasm by relative URL
// and compiles it by streaming, which requires the application/wasm type.
export default async function init() {
  const response = await fetch(new URL("converter_wasm_bg.wasm", import.meta.url))
  const { instance } = await WebAssembly.instantiateStreaming(response)
  readerFixtures = await (await fetch(new URL("reader_contract.json", import.meta.url))).json()
  initialised = true
  return instance.exports
}

function requireInitialised() {
  if (!initialised) throw new Error("Fixture runtime used before init()")
}

// This deliberately recognises only the checked-in sample's bytes. It is not
// an EPUB parser. CONVERTER_RUNTIME=built exercises Rust inspection in CI;
// the fixture proves browser queue/presentation/transport behaviour locally.
export function inspect_epub(bytes) {
  requireInitialised()
  let checksum = 2166136261
  for (const byte of bytes) checksum = Math.imul(checksum ^ byte, 16777619) >>> 0
  if (bytes.length !== 3204 || checksum !== 3869543550) throw new Error("Invalid EPUB archive")
  return JSON.stringify({ bookTitle: "Test Multi Feature Book", bookAuthor: "Equipe de Testes", chapters: [] })
}

// These reader fixtures are pre-authored golden responses, not a JS reader
// implementation. Unknown source chapters fail instead of using a JS parser,
// sanitizer, paginator or matcher. Real WASM acceptance remains separate.
export function reader_inspect_epub_json_v1(bytes) {
  inspect_epub(bytes)
  return JSON.stringify(readerFixtures.sampleBook)
}

export function reader_chapter_json_v1(json) {
  requireInitialised()
  const request = JSON.parse(json)
  const layouts = readerFixtures.layouts[request.html]
  if (!layouts) throw new Error("No golden reader fixture for this chapter.")
  const query = ["needle", "café", "missing", "chapterOlá"].includes(request.searchText) ? request.searchText : ""
  const audio = request.audioText === "narrated words" ? request.audioText : ""
  return JSON.stringify(layouts[`${query}|${audio}`])
}

export function tts_catalog_json_v2() {
  requireInitialised()
  return JSON.stringify({
    version: 2,
    providers: [
      {
        provider: "piper",
        runtime: "piper",
        revision: "fixture",
        targets: ["web"],
        capabilities: { audio_bytes: true, online: false },
      },
    ],
    models: [
      {
        id: "pt_BR-faber-medium",
        engine: "piper",
        revision: "fixture",
        artifacts: [],
        runtime_available: true,
      },
    ],
  })
}
