import { loadConverterRuntime } from "runtime/converter_runtime"

/** Additive reader API; the legacy inspect_epub export remains unchanged. */
export async function inspectReaderBook(file) {
  const runtime = await loadConverterRuntime()
  if (typeof runtime.reader_inspect_epub_json_v1 !== "function") throw new Error("The embedded runtime does not provide reader_inspect_epub_json_v1.")
  const document = JSON.parse(runtime.reader_inspect_epub_json_v1(new Uint8Array(await file.arrayBuffer())))
  if (!document || !Array.isArray(document.chapters)) throw new Error("Invalid reader book document.")
  return document
}

/** Rust alone produces the HTML, safe CSS and UTF-16 offset mappings. */
export async function renderReaderChapter(request) {
  const runtime = await loadConverterRuntime()
  if (typeof runtime.reader_chapter_json_v1 !== "function") throw new Error("The embedded runtime does not provide reader_chapter_json_v1.")
  const result = JSON.parse(runtime.reader_chapter_json_v1(JSON.stringify(request)))
  if (result?.version !== 1 || result.offsetUnit !== "utf16" || typeof result.text !== "string" ||
      typeof result.css !== "string" || !Array.isArray(result.pages) || !Array.isArray(result.searchMatches)) {
    throw new Error("Unsupported reader chapter contract.")
  }
  return result
}
