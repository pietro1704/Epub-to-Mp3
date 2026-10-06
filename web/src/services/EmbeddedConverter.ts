import type { BookTextDocument } from "../types/conversion";

export type EmbeddedCapability = "metadata" | "chapter-preview" | "audio-conversion";

export type EmbeddedUnavailableReason =
  | "audio-conversion-not-implemented"
  | "capability-not-supported";

export class EmbeddedCapabilityUnavailableError extends Error {
  readonly code = "EMBEDDED_CAPABILITY_UNAVAILABLE" as const;
  readonly mode = "embedded" as const;
  readonly capability: EmbeddedCapability;
  readonly reason: EmbeddedUnavailableReason;

  constructor(
    capability: EmbeddedCapability,
    reason: EmbeddedUnavailableReason = "capability-not-supported",
  ) {
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
  convertToAudio(file: Blob): Promise<never>;
}

/** Explicit capability registry. No HTTP fallback is allowed in embedded mode. */
export const embeddedCapabilities = {
  mode: "embedded" as const,
  available: new Set<EmbeddedCapability>(),
  unavailable: new Set<EmbeddedCapability>([
    "metadata",
    "chapter-preview",
    "audio-conversion",
  ]),
} as const;

export function createUnavailableEmbeddedConverter(): EmbeddedConverter {
  const unavailable = (capability: EmbeddedCapability): never => {
    const reason: EmbeddedUnavailableReason =
      capability === "audio-conversion"
        ? "audio-conversion-not-implemented"
        : "capability-not-supported";
    throw new EmbeddedCapabilityUnavailableError(capability, reason);
  };

  return {
    mode: "embedded",
    capabilities: embeddedCapabilities.available,
    inspect: async () => unavailable("metadata"),
    previewChapter: async () => unavailable("chapter-preview"),
    convertToAudio: async () => unavailable("audio-conversion"),
  };
}

export const embeddedConverter = createUnavailableEmbeddedConverter();
