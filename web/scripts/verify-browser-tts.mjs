import { chromium } from "@playwright/test";
import { startBrowserServer } from "./browser-server.mjs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
const root = resolve(import.meta.dirname, "../..");
const production = process.env.TTS_BROWSER_MODE === "production";
const port = production ? 5178 : 5177;
const fixturePath = process.env.TTS_BROWSER_AUDIO_FIXTURE;
const output = resolve(root, `.reports/tts-preferences/${production ? "browser-production" : "browser"}${fixturePath ? "-fixture" : ""}`);
await mkdir(output, { recursive: true });
const server = await startBrowserServer({ root, production, port });
const { origin } = server;
let browser;
let page;
try {
  browser = await chromium.launch({ executablePath: process.env.TTS_BROWSER_EXECUTABLE, headless: true, channel: "chromium" });
  const context = await browser.newContext();
  if (fixturePath) {
    // A diagnostic transport fixture isolates orchestration/storage from inference.
    // These timings are never reported as a Piper synthesis benchmark.
    const bytes = Array.from((await readFile(fixturePath)).subarray(0, 9_216));
    await context.addInitScript(bytes => {
      const NativeWorker = Worker;
      window.Worker = class {
        onmessage = null;
        stopped = false;
        constructor(url, options) {
          if (!String(url).includes("BrowserPiperWorker")) return new NativeWorker(url, options);
        }
        postMessage() {
          queueMicrotask(() => { if (!this.stopped) this.onmessage?.({ data: { wav: Uint8Array.from(bytes).buffer } }); });
        }
        terminate() { this.stopped = true; }
      };
    }, bytes);
  }
  if (production) await context.addInitScript(() => {
    window.__ttsAudioObservation = { started: 0, firstPlayableMs: null, created: [] };
    const create = URL.createObjectURL.bind(URL);
    URL.createObjectURL = blob => {
      const observation = window.__ttsAudioObservation;
      observation.created.push({ type: blob.type, bytes: blob.size, at: performance.now(), started: observation.started });
      if (blob.type === "audio/mpeg" && observation.started && observation.firstPlayableMs === null) {
        observation.firstPlayableMs = performance.now() - observation.started;
      }
      return create(blob);
    };
  });
  const errors = [];
  const modelDownloads = [];
  page = await context.newPage();
  page.on("pageerror", error => errors.push(String(error)));
  // Reuse the already verified local weights as a deterministic download transport.
  // Inference and Rust/WASM orchestration remain actual browser executables.
  await page.route("https://huggingface.co/**", async route => {
    const url = route.request().url();
    modelDownloads.push(url);
    if (!url.includes("pt_BR-faber-medium.onnx")) throw new Error(`Unexpected model download: ${url}`);
    await route.fulfill({ path: resolve(root, "models", url.includes(".onnx.json") ? "pt_BR-faber-medium.onnx.json" : "pt_BR-faber-medium.onnx"), contentType: "application/octet-stream", headers: { "access-control-allow-origin": "*" } });
  });
  await page.goto(origin, { waitUntil: "domcontentloaded" });
  const scripts = await page.locator("script[src]").evaluateAll(elements => elements.map(element => element.src));
  if (production && (!scripts.some(source => source.includes("/assets/")) || scripts.some(source => source.includes("/@vite/")))) {
    throw new Error("Production verification must load the built assets, not the development server.");
  }
  // Installation acts on the selected catalogue model, not a Faber-only button.
  await page.getByRole("combobox", { name: /^(Voz principal|Primary voice)$/ }).selectOption("pt_BR-faber-medium");
  if (modelDownloads.length !== 0) throw new Error("Selecting a voice must not install its model.");
  await page.getByRole("button", { name: /^(Instalar modelo selecionado|Install selected model)$/ }).click();
  await page.getByText(/^(Modelo selecionado instalado|Selected model installed)$/).waitFor();
  if (modelDownloads.length !== 2) throw new Error("Model installation must fetch exactly two verified artifacts.");
  await page.unroute("https://huggingface.co/**");
  await page.route("https://**", route => route.abort("internetdisconnected"));
  await page.locator("#file").setInputFiles(resolve(root, "web/public/sample.epub"));
  const started = Date.now();
  if (production) await page.evaluate(() => { window.__ttsAudioObservation.started = performance.now(); });
  await page.getByRole("button", { name: /Converter agora|Convert now/ }).click();
  let terminalArtifacts;
  if (production) {
    const terminal = await page.waitForFunction(() => {
      if (!document.querySelector(".status-chip--success")) return false;
      const artifacts = Array.from(document.querySelectorAll("a.chapter-item__download[download$='.mp3']"), anchor => ({ name: anchor.download, url: anchor.href }));
      if (artifacts.length !== 2 || new Set(artifacts.map(artifact => artifact.name)).size !== 2) return false;
      // Capture the terminal render atomically before asynchronous decoding.
      return { state: "finished", artifacts };
    }, undefined, { timeout: 120_000 });
    terminalArtifacts = await terminal.jsonValue();
    await terminal.dispose();
  } else {
    await page.waitForFunction(async () => (await (await import("/src/services/ConversionService.ts")).conversionClient.getRecentJobs()).length > 0, undefined, { timeout: 30_000 });
  }
  const evidence = await page.evaluate(async ({ production, terminalArtifacts }) => {
    if (production) {
      const audio = new AudioContext();
      const outputs = [];
      for (const artifact of terminalArtifacts.artifacts) {
        const bytes = await (await fetch(artifact.url)).arrayBuffer();
        const decoded = await audio.decodeAudioData(bytes.slice(0));
        const peak = decoded.getChannelData(0).reduce((peak, value) => Math.max(peak, Math.abs(value)), 0);
        if (!(decoded.duration > 0) || !(peak > 0.001)) throw new Error("Invalid or silent production audio");
        outputs.push({ name: artifact.name, bytes: Array.from(new Uint8Array(bytes)), durationSeconds: decoded.duration, peak });
      }
      await audio.close();
      if (outputs.length !== 2 || window.__ttsAudioObservation.firstPlayableMs === null) throw new Error(`Production artifacts or progressive audio were not published: ${JSON.stringify({ outputs: outputs.map(output => output.name), observation: window.__ttsAudioObservation })}`);
      return { snapshot: { state: terminalArtifacts.state, engine: "piper", voice: "pt_BR-faber-medium" }, firstPlayableMs: window.__ttsAudioObservation.firstPlayableMs, elapsedMs: performance.now() - window.__ttsAudioObservation.started, outputs };
    }
    const { conversionClient } = await import("/src/services/ConversionService.ts");
    const started = performance.now();
    const { jobId } = (await conversionClient.getRecentJobs())[0];
    let firstPlayableMs;
    const controller = new AbortController();
    const deadline = setTimeout(() => controller.abort(), 120_000);
    let snapshot;
    try { snapshot = await conversionClient.poll(jobId, {
      signal: controller.signal,
      intervalMs: 50,
      onSnapshot: async () => {
        if (firstPlayableMs !== undefined) return;
        const manifest = await conversionClient.getChapterManifest(jobId, 0);
        if (manifest?.chunks.length) firstPlayableMs = performance.now() - started;
      },
    }); } finally { clearTimeout(deadline); }
    if (snapshot.state !== "finished" || snapshot.outputs?.length !== 2) throw new Error(JSON.stringify(snapshot));
    const audio = new AudioContext();
    const outputs = [];
    for (const artifact of snapshot.outputs) {
      const bytes = await (await fetch(artifact.url)).arrayBuffer();
      const decoded = await audio.decodeAudioData(bytes.slice(0));
      const samples = decoded.getChannelData(0);
      const peak = samples.reduce((peak, value) => Math.max(peak, Math.abs(value)), 0);
      if (!(decoded.duration > 0) || !(peak > 0.001)) throw new Error("Invalid or silent synthesized audio");
      outputs.push({ name: artifact.name, bytes: Array.from(new Uint8Array(bytes)), durationSeconds: decoded.duration, peak });
    }
    await audio.close();
    return { snapshot, firstPlayableMs, elapsedMs: performance.now() - started, outputs };
  }, { production, terminalArtifacts });
  for (const artifact of evidence.outputs) {
    await writeFile(resolve(output, artifact.name), Buffer.from(artifact.bytes));
    delete artifact.bytes;
  }
  if (production) {
    evidence.persisted = await page.evaluate(async () => {
      const records = await new Promise((resolve, reject) => {
        const open = indexedDB.open("ebook-tts.jobs.v1", 1);
        open.onerror = () => reject(open.error);
        open.onsuccess = () => {
          const database = open.result;
          const transaction = database.transaction("jobs", "readonly");
          const request = transaction.objectStore("jobs").getAll();
          request.onsuccess = () => resolve(request.result);
          request.onerror = () => reject(request.error);
          transaction.oncomplete = () => database.close();
        };
      });
      const job = records.find(record => record.audio.length === 2);
      if (!job || job.snapshot.state !== "finished" || job.preferences.primary.model_id !== "pt_BR-faber-medium") throw new Error("Completed audio or immutable voice was not persisted");
      localStorage.setItem("ebook-tts.preferences.v1", JSON.stringify({ primary: { engine: "edge", model_id: null, voice: null }, secondary: null, allow_online_fallback: false }));
      return { jobId: job.jobId, state: job.snapshot.state, voice: job.preferences.primary.model_id, audioBytes: job.audio.map(artifact => artifact.blob.size) };
    });
    await page.reload({ waitUntil: "domcontentloaded" });
    await page.getByRole("tab", { name: /3\. Ouvir e baixar|3\. Listen & download/ }).click();
    const restored = page.locator(".ready-downloads__item").first();
    await restored.waitFor({ timeout: 15_000 });
    await restored.click();
    await page.waitForFunction(() => document.querySelectorAll("a.chapter-item__download[download$='.mp3']").length === 2);
    evidence.restoredAfterReload = await page.evaluate(async () => {
      const audio = new AudioContext();
      const outputs = [];
      for (const artifact of document.querySelectorAll("a.chapter-item__download[download$='.mp3']")) {
        const bytes = await (await fetch(artifact.href)).arrayBuffer();
        const decoded = await audio.decodeAudioData(bytes);
        const peak = decoded.getChannelData(0).reduce((peak, value) => Math.max(peak, Math.abs(value)), 0);
        if (!(decoded.duration > 0) || !(peak > 0.001)) throw new Error("Restored artifact is unplayable or silent");
        outputs.push({ name: artifact.download, durationSeconds: decoded.duration, peak });
      }
      await audio.close();
      return outputs;
    });
  }
  await page.screenshot({ path: resolve(output, "app.png"), fullPage: true });
  await writeFile(resolve(output, "evidence.json"), JSON.stringify({ ...evidence, realPiperSynthesis: !fixturePath, productionBundle: production, scripts, commandElapsedMs: Date.now() - started, modelDownloads: modelDownloads.length, internetBlockedDuringSynthesis: true, pageErrors: errors }, null, 2));
  if (errors.length) throw new Error(`Browser runtime errors: ${errors.join("; ")}`);
  console.log(JSON.stringify({ state: evidence.snapshot.state, outputs: evidence.outputs, firstPlayableMs: evidence.firstPlayableMs, elapsedMs: evidence.elapsedMs, pageErrors: errors }));
} catch (error) {
  if (page && !page.isClosed()) {
    try {
      const storage = await page.evaluate(async () => {
        const files = [];
        let directoryError;
        try {
          const directory = await (await navigator.storage.getDirectory()).getDirectoryHandle("piper");
          for await (const [name, handle] of directory.entries()) {
            if (handle.kind === "file") {
              const file = await handle.getFile();
              files.push({ name, size: file.size, lastModified: file.lastModified });
            }
          }
        } catch (failure) { directoryError = String(failure); }
        return { estimate: await navigator.storage.estimate(), persistent: await navigator.storage.persisted(), files, directoryError, origin: location.origin, audioObservation: window.__ttsAudioObservation };
      });
      await writeFile(resolve(output, "failure-storage.json"), JSON.stringify(storage, null, 2));
    } catch (diagnosticError) {
      await writeFile(resolve(output, "failure-storage.json"), JSON.stringify({ diagnosticError: String(diagnosticError) }, null, 2));
    }
    await page.screenshot({ path: resolve(output, "failure.png"), fullPage: true });
    await writeFile(resolve(output, "failure.txt"), `${String(error)}\n${await page.locator("body").innerText()}`);
  }
  throw error;
} finally {
  try { await browser?.close(); }
  finally { await server.stop(); }
}
