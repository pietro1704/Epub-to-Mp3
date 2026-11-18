import { BookQueue } from "runtime/book_queue"
import { loadConverterRuntime } from "runtime/converter_runtime"
import { ReaderSession } from "runtime/reader_session"
import { inspectReaderBook, renderReaderChapter } from "runtime/reader_runtime"
import { loadReaderPreferences, saveReaderPreferences } from "runtime/reader_preferences"
import { createConversionPlatform } from "runtime/conversion_platform"
import { ConversionWorkspace } from "runtime/conversion_workspace"
import { latencyObservations } from "runtime/latency_observation"

/** Inspect locally. Neither File nor its bytes are sent to a server. */
export async function inspectBook(file) {
  const runtime = await loadConverterRuntime()
  const document = JSON.parse(runtime.inspect_epub(new Uint8Array(await file.arrayBuffer())))
  if (!document || !Array.isArray(document.chapters)) throw new Error("Invalid EPUB inspection result.")
  return document
}

// Turbo replaces the document body for preferences, but keeps this module and
// the File objects alive. Controllers subscribe again when their view mounts.
export const bookQueue = new BookQueue(inspectBook)

// Access to localStorage itself can throw in restricted browser contexts.
let pageStorage
try { pageStorage = window.localStorage } catch { /* Preferences stay in memory. */ }
export const readerSession = new ReaderSession({
  inspect: inspectReaderBook, render: renderReaderChapter,
  preferences: loadReaderPreferences(pageStorage),
  savePreferences: (preferences) => saveReaderPreferences(pageStorage, preferences),
  latency: latencyObservations,
})
bookQueue.subscribe((books) => {
  if (readerSession.state.bookId && !books.some((book) => book.id === readerSession.state.bookId)) readerSession.close()
})

/** @type {Promise<ConversionWorkspace> | undefined} */
let conversion
/**
 * The conversion workspace, created on first use. The test page may name a
 * fixture synthesis module (rendered only when Rails.env.test?) so system
 * tests convert without model files; production renders no such tag.
 */
export function conversionWorkspace() {
  conversion ??= (async () => {
    const fixture = document.querySelector('meta[name="conversion-test-fixture"]')?.getAttribute("content")
    const synthesis = fixture ? (await import(fixture)).synthesis : undefined
    const { client } = createConversionPlatform({ storage: pageStorage, synthesis })
    return new ConversionWorkspace({ client, storage: pageStorage })
  })()
  return conversion
}
