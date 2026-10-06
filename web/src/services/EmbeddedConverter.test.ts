import { describe, expect, it } from "vitest";

import {
  EmbeddedCapabilityUnavailableError,
  embeddedCapabilities,
  embeddedConverter,
} from "../services/EmbeddedConverter";

describe("embedded web capability registry", () => {
  it("keeps embedded mode explicit and does not advertise unsupported capabilities", () => {
    expect(embeddedCapabilities.mode).toBe("embedded");
    expect(embeddedCapabilities.available.size).toBe(0);
    expect(embeddedCapabilities.unavailable).toEqual(
      new Set(["metadata", "chapter-preview", "audio-conversion"]),
    );
  });

  it("returns a typed unavailable error for audio conversion", async () => {
    await expect(
      embeddedConverter.convertToAudio(new Blob()),
    ).rejects.toMatchObject({
      name: "EmbeddedCapabilityUnavailableError",
      code: "EMBEDDED_CAPABILITY_UNAVAILABLE",
      mode: "embedded",
      capability: "audio-conversion",
      reason: "audio-conversion-not-implemented",
    });
    await expect(
      embeddedConverter.convertToAudio(new Blob()),
    ).rejects.toBeInstanceOf(EmbeddedCapabilityUnavailableError);
  });

  it("does not silently fall back to HTTP for preview", async () => {
    await expect(embeddedConverter.previewChapter(new Blob(), 0)).rejects.toMatchObject({
      capability: "chapter-preview",
      mode: "embedded",
    });
  });
});
