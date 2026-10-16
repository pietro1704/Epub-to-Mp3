import initWasm, { inspect_epub } from "../wasm/converter_wasm";
import type { BookTextChapter, BookTextDocument, DownloadAsset } from "../types/conversion";

export type EmbeddedCapability = "metadata" | "chapter-preview" | "audio-conversion";
export type EmbeddedUnavailableReason = "audio-conversion-not-implemented" | "capability-not-supported";

export class EmbeddedCapabilityUnavailableError extends Error {
  readonly code = "EMBEDDED_CAPABILITY_UNAVAILABLE" as const;
  readonly mode = "embedded" as const;
  readonly capability: EmbeddedCapability;
  readonly reason: EmbeddedUnavailableReason;

  constructor(capability: EmbeddedCapability, reason: EmbeddedUnavailableReason = "capability-not-supported") {
    super(`Embedded ${capability} is unavailable: ${reason}.`);
    this.name = "EmbeddedCapabilityUnavailableError";
    this.capability = capability;
    this.reason = reason;
  }
}

export interface EmbeddedConverter {
  readonly mode: "embedded";
  readonly capabilities: ReadonlySet<EmbeddedCapability>;
  inspect(file: Blob): Promise<Pick<BookTextDocument, "bookTitle" | "bookAuthor" | "chapters">>;
  previewChapter(file: Blob, chapterIndex: number): Promise<string>;
  convertToAudio(file: Blob): Promise<DownloadAsset[]>;
}

export const embeddedCapabilities = {
  mode: "embedded" as const,
  available: new Set<EmbeddedCapability>(["metadata", "chapter-preview", "audio-conversion"]),
  unavailable: new Set<EmbeddedCapability>(),
} as const;

let wasmReady: Promise<void> | undefined;
async function ensureWasm(): Promise<void> {
  wasmReady ??= initWasm().then(() => undefined);
  await wasmReady;
}

async function inspect(file: Blob): Promise<BookTextDocument> {
  await ensureWasm();
  return JSON.parse(inspect_epub(new Uint8Array(await file.arrayBuffer()))) as BookTextDocument;
}

export const embeddedConverter: EmbeddedConverter = {
  mode: "embedded",
  capabilities: embeddedCapabilities.available,
  inspect,
  previewChapter: async (file, chapterIndex) => {
    const chapter = (await inspect(file)).chapters[chapterIndex] as BookTextChapter | undefined;
    if (!chapter) throw new EmbeddedCapabilityUnavailableError("chapter-preview");
    return chapter.text;
  },
  convertToAudio: async file => {
    const { conversionClient } = await import("./ConversionService");
    const source = file instanceof File ? file : new File([file], "book.epub", { type: "application/epub+zip" });
    const { jobId } = await conversionClient.submit({ file: source, engine: "piper", footnoteMode: "inline" });
    const result = await conversionClient.poll(jobId);
    if (result.state !== "finished") throw new Error(result.error ?? `Browser conversion ${result.state}`);
    return result.outputs ?? [];
  },
};
