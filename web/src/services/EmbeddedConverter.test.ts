import { beforeEach, describe, expect, it, vi } from "vitest";
const client = vi.hoisted(() => ({ submit: vi.fn(), poll: vi.fn() }));
vi.mock("./ConversionService", () => ({ conversionClient: client }));
import { embeddedCapabilities, embeddedConverter } from "./EmbeddedConverter";
beforeEach(() => { client.submit.mockReset(); client.poll.mockReset(); });
describe("embedded web capability registry", () => {
  it("advertises local audio alongside Rust metadata and chapter previews", () => {
    expect(embeddedCapabilities.mode).toBe("embedded");
    expect(embeddedCapabilities.available).toEqual(new Set(["metadata", "chapter-preview", "audio-conversion"]));
    expect(embeddedCapabilities.unavailable.size).toBe(0);
  });
  it("routes audio through the real embedded job seam and returns artifacts", async () => {
    const outputs = [{ name: "chapter-1.wav", url: "blob:audio" }];
    client.submit.mockResolvedValue({ jobId: "local" });
    client.poll.mockResolvedValue({ state: "finished", outputs });
    expect(await embeddedConverter.convertToAudio(new Blob(["EPUB"]))).toEqual(outputs);
    expect(client.submit).toHaveBeenCalledWith(expect.objectContaining({ engine: "piper", file: expect.any(File) }));
    expect(client.poll).toHaveBeenCalledWith("local");
  });
  it("preserves actual missing-model and synthesis errors", async () => {
    client.submit.mockResolvedValue({ jobId: "local" });
    client.poll.mockResolvedValue({ state: "failed", error: "Install Faber medium explicitly before converting." });
    await expect(embeddedConverter.convertToAudio(new Blob())).rejects.toThrow("Install Faber medium explicitly");
  });
});
