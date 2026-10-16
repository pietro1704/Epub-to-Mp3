import { describe, expect, it, vi } from "vitest";
vi.mock("../wasm/converter_wasm", () => ({ default: vi.fn(), ConversionSession: vi.fn(), inspect_epub: vi.fn() }));
import { BrowserConversionClient, type BrowserRuntime } from "../services/BrowserConversionClient";
import { edge } from "../services/TtsPreferences";
describe("WASM capability boundary", () => {
  it("rejects browser Edge explicitly without routing to a remote service", async () => {
    const runtime: BrowserRuntime = { inspect: vi.fn(async () => ({ chapters: [{ index: 0, name: "Chapter", text: "Texto", charCount: 5 }] })), create: vi.fn(), synthesize: vi.fn() };
    const client = new BrowserConversionClient(runtime);
    const network = vi.spyOn(globalThis, "fetch");
    await expect(client.submit({ file: new File([], "book.epub"), engine: "edge", footnoteMode: "inline", tts_preferences: { primary: edge, secondary: null, allow_online_fallback: false } })).rejects.toThrow("Edge is unavailable");
    expect(network).not.toHaveBeenCalled();
    expect(runtime.create).not.toHaveBeenCalled();
    network.mockRestore();
  });
});
