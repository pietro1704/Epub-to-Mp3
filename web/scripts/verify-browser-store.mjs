import { chromium } from "@playwright/test";
import { spawn } from "node:child_process";
import { resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

const root = resolve(import.meta.dirname, "../..");
const server = spawn("mise", ["exec", "--", "npm", "run", "dev", "--", "--host", "127.0.0.1", "--port", "5177", "--strictPort"], { cwd: resolve(root, "web"), stdio: "ignore" });
let browser;
try {
  for (let attempt = 0; ; attempt++) {
    try { if ((await fetch("http://127.0.0.1:5177")).ok) break; } catch { /* Wait for the local frontend. */ }
    if (attempt === 100) throw new Error("Storage test frontend did not start");
    await delay(200);
  }
  browser = await chromium.launch({ executablePath: process.env.TTS_BROWSER_EXECUTABLE, headless: true, channel: "chromium" });
  const page = await browser.newPage();
  await page.route("https://**", route => route.abort("internetdisconnected"));
  await page.goto("http://127.0.0.1:5177", { waitUntil: "domcontentloaded" });
  const evidence = await page.evaluate(async () => {
    const { IndexedDBBrowserJobStore } = await import("/src/services/BrowserJobStore.ts");
    const store = new IndexedDBBrowserJobStore();
    const pcm = new Uint8Array(65_536); pcm[pcm.length - 1] = 173;
    const job = {
      jobId: "storage-fixture", snapshot: { jobId: "storage-fixture", state: "running" },
      document: { jobId: "storage-fixture", chapters: [{ index: 0, name: "Chapter", text: "Texto", charCount: 5 }] },
      preferences: { primary: { engine: "piper", model_id: "pt_BR-faber-medium", voice: null }, secondary: null, allow_online_fallback: false },
      language: "pt-BR", audio: [{ chapterIndex: 0, name: "chapter-1.mp3", blob: new Blob([pcm], { type: "audio/mpeg" }) }],
    };
    await Promise.race([store.save(job), new Promise((_, reject) => setTimeout(() => reject(new Error("IndexedDB Blob commit did not complete within five seconds")), 5000))]);
    const restored = (await new IndexedDBBrowserJobStore().list()).find(record => record.jobId === job.jobId);
    if (!restored || restored.preferences.primary.model_id !== "pt_BR-faber-medium") throw new Error("Stored voice identity changed");
    const bytes = new Uint8Array(await restored.audio[0].blob.arrayBuffer());
    if (bytes.length !== pcm.length || bytes[bytes.length - 1] !== 173) throw new Error("Blob round trip lost audio bytes");
    await store.remove(job.jobId);
    return { committed: true, restoredBytes: bytes.length };
  });
  console.log(JSON.stringify(evidence));
} finally {
  await browser?.close();
  server.kill("SIGTERM");
}
