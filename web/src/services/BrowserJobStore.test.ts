import { describe, expect, it } from "vitest";
import { IndexedDBBrowserJobStore, MemoryBrowserJobStore, type StoredBrowserJob } from "./BrowserJobStore";
const fixture = (): StoredBrowserJob => ({
  jobId: "book",
  snapshot: { jobId: "book", state: "finished", outputs: [] },
  document: { jobId: "book", chapters: [{ index: 0, name: "Chapter", text: "Texto", charCount: 5 }] },
  preferences: { primary: { engine: "piper", model_id: "pt_BR-faber-medium", voice: null }, secondary: null, allow_online_fallback: false },
  language: "pt-BR",
  audio: [{ chapterIndex: 0, name: "chapter.mp3", blob: new Blob(["audio"], { type: "audio/mpeg" }) }],
});
describe("browser job store boundary", () => {
  it("copies mutable state while preserving immutable audio Blobs across readers", async () => {
    const store = new MemoryBrowserJobStore();
    const job = fixture();
    const originalAudio = job.audio[0].blob;
    await store.save(job);
    job.preferences.primary.engine = "edge";
    job.snapshot.state = "cancelled";
    job.document.chapters[0].text = "Changed";
    job.audio.length = 0;
    const restored = (await store.list())[0];
    expect(restored.preferences.primary.engine).toBe("piper");
    expect(restored.snapshot.state).toBe("finished");
    expect(restored.document.chapters[0].text).toBe("Texto");
    expect(restored.audio[0].blob).toBe(originalAudio);
    restored.snapshot.state = "failed";
    expect((await store.list())[0].snapshot.state).toBe("finished");
    await store.remove("book");
    expect(await store.list()).toEqual([]);
  });
  it("fails explicitly when durable browser storage is unavailable", async () => {
    const store = new IndexedDBBrowserJobStore(undefined);
    await expect(store.save(fixture())).rejects.toThrow("Enable IndexedDB storage");
    await expect(store.list()).rejects.toThrow("Enable IndexedDB storage");
  });
});
