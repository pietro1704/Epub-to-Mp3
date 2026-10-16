import initWasm, { ConversionSession } from "../wasm/converter_wasm";
import { embeddedConverter } from "./EmbeddedConverter";
import { loadTtsPreferences } from "./TtsPreferences";
import { cancelPiper, synthesizePiper } from "./BrowserPiper";
import { IndexedDBBrowserJobStore, type BrowserJobStore, type StoredBrowserAudio } from "./BrowserJobStore";
import type { ConversionClient, PollOptions, UploadResponse } from "./ConversionService";
import type { BookTextDocument, ChapterStreamManifest, ConversionFormValues, JobSnapshot, TtsPreferences, TtsSelection } from "../types/conversion";

export const browserVoiceId = "pt_BR-faber-medium";
export const browserWasmPaths = { onnxWasm: "/tts/", piperData: "/tts/piper_phonemize.data", piperWasm: "/tts/piper_phonemize.wasm" };
export async function installedBrowserVoices(): Promise<string[]> {
  return (await import("@mintplex-labs/piper-tts-web")).stored();
}
let modelInstallation: Promise<void> | undefined;
export async function installBrowserFaber(): Promise<void> {
  if (modelInstallation) return modelInstallation;
  modelInstallation = (async () => {
    const directory = await (await navigator.storage.getDirectory()).getDirectoryHandle("piper", { create: true });
    await installFaberArtifacts({
      fetchArtifact: async url => { const response = await fetch(url); if (!response.ok) throw new Error(`Model download failed: HTTP ${response.status}`); return response.blob(); },
      writeFile: async (name, blob) => {
        const writer = await (await directory.getFileHandle(name, { create: true })).createWritable();
        try { await writer.write(blob); await writer.close(); }
        catch (error) { try { await writer.abort(); } catch { /* Writer may already be closed. */ } throw error; }
      },
      readFile: async name => (await directory.getFileHandle(name)).getFile(),
      removeFile: name => directory.removeEntry(name),
      digest: data => crypto.subtle.digest("SHA-256", data),
    });
    await verifyBrowserFaber(directory);
  })();
  try { await modelInstallation; } finally { modelInstallation = undefined; }
}
export interface FaberInstallerIO {
  fetchArtifact(url: string): Promise<Blob>;
  writeFile(name: string, blob: Blob): Promise<void>;
  readFile(name: string): Promise<Blob>;
  removeFile(name: string): Promise<void>;
  digest(data: ArrayBuffer): Promise<ArrayBuffer>;
}
/** Stage and verify the entire pair before publishing; await every OPFS write. */
export async function installFaberArtifacts(io: FaberInstallerIO): Promise<void> {
  // Reinstalling an already verified voice must never risk replacing its files.
  try {
    let complete = true;
    for (const artifact of faberArtifacts) {
      const existing = await io.readFile(artifact.name);
      if (existing.size !== artifact.bytes) { complete = false; break; }
      const digest = await io.digest(await existing.arrayBuffer());
      const hash = Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("");
      if (hash !== artifact.sha256) { complete = false; break; }
    }
    if (complete) return;
  } catch { /* A missing or unreadable pair still requires explicit installation. */ }
  const prefix = `.faber-install-${crypto.randomUUID()}`;
  const staged = faberArtifacts.map(artifact => `${prefix}-${artifact.name}`);
  let publishing = false;
  try {
    for (const [index, artifact] of faberArtifacts.entries()) {
      const blob = await io.fetchArtifact(`https://huggingface.co/rhasspy/piper-voices/resolve/main/pt/pt_BR/faber/medium/${artifact.name}?download=true`);
      const digest = await io.digest(await blob.arrayBuffer());
      const hash = Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("");
      if (blob.size !== artifact.bytes || hash !== artifact.sha256) throw new Error(`Faber medium checksum validation failed: ${artifact.name}`);
      await io.writeFile(staged[index], blob);
    }
    publishing = true;
    verifiedArtifacts.clear();
    for (const [index, artifact] of faberArtifacts.entries()) await io.writeFile(artifact.name, await io.readFile(staged[index]));
  } catch (error) {
    if (publishing) {
      for (const artifact of faberArtifacts) { try { await io.removeFile(artifact.name); } catch { /* Only this model's incomplete published pair. */ } }
    }
    throw error;
  } finally {
    for (const name of staged) { try { await io.removeFile(name); } catch { /* A failed download may not create its staging file. */ } }
  }
}
const faberArtifacts = [
  { name: "pt_BR-faber-medium.onnx", sha256: "858555e3a064209c57088fe6bd70c4c3dc54d03eaa00c45d5ecaf43a33f95aa7", bytes: 63_201_294 },
  { name: "pt_BR-faber-medium.onnx.json", sha256: "7e694de195ae3fc36dd732c445eb04fb49b649854893cb5506b978f0d50a1d6f", bytes: 4_855 },
] as const;
const verifiedArtifacts = new Map<string, string>();
/** Verify the same immutable artifact checksums as the Rust model catalog. */
interface ArtifactDirectory {
  getFileHandle(name: string): Promise<{ getFile(): Promise<File> }>;
  removeEntry(name: string): Promise<void>;
}
export async function verifyBrowserFaber(
  directory?: ArtifactDirectory,
  digestSHA256: (data: ArrayBuffer) => Promise<ArrayBuffer> = data => crypto.subtle.digest("SHA-256", data),
): Promise<void> {
  const artifacts = directory ?? await (await navigator.storage.getDirectory()).getDirectoryHandle("piper");
  for (const artifact of faberArtifacts) {
    let file: File;
    try { file = await (await artifacts.getFileHandle(artifact.name)).getFile(); }
    catch { throw new Error("Faber medium is incomplete. Install the model before converting."); }
    const identity = `${file.size}:${file.lastModified}`;
    if (verifiedArtifacts.get(artifact.name) === identity) continue;
    const digest = await digestSHA256(await file.arrayBuffer());
    const hash = Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("");
    if (file.size !== artifact.bytes || hash !== artifact.sha256) {
      verifiedArtifacts.clear();
      for (const corrupted of faberArtifacts) {
        try { await artifacts.removeEntry(corrupted.name); } catch { /* Preserve unrelated models. */ }
      }
      throw new Error("Faber medium checksum validation failed. Corrupt model files were removed; reinstall the model.");
    }
    verifiedArtifacts.set(artifact.name, identity);
  }
}
type InspectedBook = Omit<BookTextDocument, "jobId"> & { language?: string };
interface Segment { chapter: number; index: number; total: number; text: string; selection: TtsSelection; fallback_used: boolean; }
interface Session {
  next_segment(): string;
  provider_failed(): void;
  accept_audio(wav: Uint8Array): boolean;
  chapter_audio(): Uint8Array;
  cancel(): void;
  free?(): void;
}
export interface BrowserRuntime {
  inspect(file: File): Promise<InspectedBook>;
  create(chapters: BookTextDocument["chapters"], preferences: TtsPreferences, language: string): Promise<Session>;
  synthesize(text: string, selection: TtsSelection): Promise<Uint8Array>;
  cancelSynthesis?(): void;
}
/** Injectable model-readiness I/O keeps the production synthesis boundary testable. */
export function createBrowserSynthesis(
  prepare: (selection: TtsSelection) => Promise<void> = prepareBrowserPiper,
): Pick<BrowserRuntime, "synthesize" | "cancelSynthesis"> {
  return {
    synthesize: async (text, selection) => {
      await prepare(selection);
      return synthesizePiper(text);
    },
    cancelSynthesis: cancelPiper,
  };
}
async function prepareBrowserPiper(selection: TtsSelection): Promise<void> {
  if (selection.engine !== "piper") throw new Error("Edge is unavailable in this browser. Select Faber medium; no server is used.");
  if (selection.model_id !== browserVoiceId) throw new Error("Only Faber medium is available in this browser.");
  if (modelInstallation) await modelInstallation;
  const piper = await import("@mintplex-labs/piper-tts-web");
  if (!(await piper.stored()).includes(browserVoiceId)) throw new Error("Install Faber medium explicitly before converting.");
  await verifyBrowserFaber();
}
const platformRuntime: BrowserRuntime = {
  inspect: file => embeddedConverter.inspect(file),
  create: async (chapters, preferences, language) => {
    await initWasm();
    return new ConversionSession(JSON.stringify(chapters), JSON.stringify(preferences), language);
  },
  ...createBrowserSynthesis(),
};
interface Job { snapshot: JobSnapshot; document: BookTextDocument; preferences: TtsPreferences; language: string; audio: Map<number, StoredBrowserAudio>; session?: Session; chunks: Map<number, ChapterStreamManifest>; done: Promise<void>; }
const terminal = (state: string) => ["finished", "failed", "cancelled", "interrupted"].includes(state);
/** JavaScript supplies browser I/O and synthesis; Rust owns segment planning and acceptance. */
export class BrowserConversionClient implements ConversionClient {
  readonly mode = "embedded" as const;
  private uploads = new Map<string, { file: File; document: InspectedBook }>();
  private jobs = new Map<string, Job>();
  private queue: Promise<void> = Promise.resolve();
  private restored?: Promise<void>;
  constructor(private runtime: BrowserRuntime = platformRuntime, private store: BrowserJobStore = new IndexedDBBrowserJobStore()) {}
  private ensureRestored(): Promise<void> {
    return this.restored ??= this.restore();
  }
  private async restore(): Promise<void> {
    for (const saved of await this.store.list()) {
      const snapshot = structuredClone(saved.snapshot);
      if (["running", "queued", "cancelling"].includes(snapshot.state)) snapshot.state = "interrupted";
      snapshot.outputs = [];
      const job: Job = { snapshot, document: saved.document, preferences: saved.preferences, language: saved.language, audio: new Map(), chunks: new Map(), done: Promise.resolve() };
      for (const artifact of saved.audio) {
        job.audio.set(artifact.chapterIndex, artifact);
        const url = URL.createObjectURL(artifact.blob);
        snapshot.outputs.push({ name: artifact.name, url, sizeBytes: artifact.blob.size });
        job.chunks.set(artifact.chapterIndex, { jobId: saved.jobId, chapterIndex: artifact.chapterIndex, baseUrl: "", chunks: [{ index: 0, file: artifact.name, url, text: saved.document.chapters.find(chapter => chapter.index === artifact.chapterIndex)?.text ?? "" }] });
      }
      snapshot.chaptersCompleted = job.audio.size;
      snapshot.chapterProgress = snapshot.chapterProgress?.map(chapter => ({ ...chapter, status: job.audio.has(chapter.index) ? "completed" : "pending", downloadUrl: snapshot.outputs?.find(output => output.name === `chapter-${chapter.index + 1}.mp3`)?.url }));
      this.jobs.set(saved.jobId, job);
      if (snapshot.state !== saved.snapshot.state) await this.persist(job);
    }
  }
  private persist(job: Job, committedState: Partial<JobSnapshot> = {}): Promise<void> {
    const snapshot = { ...structuredClone(job.snapshot), ...committedState };
    snapshot.outputs = snapshot.outputs?.map(output => ({ ...output, url: "" }));
    snapshot.chapterProgress = snapshot.chapterProgress?.map(chapter => ({ ...chapter, downloadUrl: undefined }));
    return this.store.save({ jobId: snapshot.jobId, snapshot, document: structuredClone(job.document), preferences: structuredClone(job.preferences), language: job.language, audio: [...job.audio.values()] });
  }
  async upload(file: File): Promise<UploadResponse> {
    await this.ensureRestored();
    const inspected = await this.runtime.inspect(file);
    const document = { ...inspected, chapters: inspected.chapters.map((chapter, index) => ({ ...chapter, index, charCount: chapter.text.length })) };
    const uploadId = crypto.randomUUID();
    this.uploads.set(uploadId, { file, document });
    return { uploadId, fileName: file.name, bookTitle: document.bookTitle, bookAuthor: document.bookAuthor };
  }
  async submit(request: ConversionFormValues): Promise<{ jobId: string }> {
    const unsupported = [request.sections, request.fromChapterToEnd, request.fromChapterToChapter, request.priority];
    if (unsupported.some(Boolean) || request.footnoteMode !== "inline" || request.enableCharacterVoices || request.formattingCues || request.multiEngineParallel || request.exportToIphone || request.bitrate || request.sampleRate || request.channels) {
      throw new Error("This browser does not support the selected advanced conversion options.");
    }
    const preferences: TtsPreferences = structuredClone(request.tts_preferences ?? loadTtsPreferences());
    if (preferences.primary.engine !== "piper" || preferences.primary.model_id !== browserVoiceId || preferences.secondary?.engine === "edge") {
      throw new Error("Edge is unavailable in this browser. Choose Faber medium without an online secondary voice.");
    }
    await this.ensureRestored();
    let upload = request.uploadId ? this.uploads.get(request.uploadId) : undefined;
    if (!upload && request.file) upload = this.uploads.get((await this.upload(request.file)).uploadId);
    if (!upload) throw new Error("Select an EPUB in this browser session.");
    let chapters = upload.document.chapters;
    if (request.chapters?.trim()) {
      const match = /^(\d+)(?:-(\d+))?$/.exec(request.chapters.trim());
      if (!match) throw new Error("Browser chapter selection must be a chapter number or inclusive range, for example 1-2.");
      const start = Number(match[1]); const end = Number(match[2] ?? match[1]);
      if (start < 1 || end < start || end > chapters.length) throw new Error("Invalid chapter range.");
      chapters = chapters.slice(start - 1, end);
    }
    if (!chapters.some(chapter => chapter.text.trim())) throw new Error("Selected chapters contain no readable text.");
    const jobId = crypto.randomUUID();
    const document = { ...upload.document, chapters, jobId };
    const language = request.language ?? upload.document.language ?? "pt-BR";
    const job: Job = { document, preferences, language, audio: new Map(), chunks: new Map(), done: Promise.resolve(), snapshot: { jobId, state: "queued", bookTitle: document.bookTitle, bookAuthor: document.bookAuthor, chaptersTotal: chapters.length, chaptersCompleted: 0, progressPercent: 0, engine: preferences.primary.engine, voice: preferences.primary.model_id ?? preferences.primary.voice ?? undefined, outputs: [], chapterProgress: chapters.map(c => ({ index: c.index, name: c.name, chars: c.charCount, status: "pending" })) } };
    await this.persist(job);
    this.jobs.set(jobId, job);
    job.done = this.queue.then(() => this.execute(job));
    this.queue = job.done.catch(() => undefined);
    return { jobId };
  }
  private async execute(job: Job): Promise<void> {
    if (this.isCancelled(job)) return;
    const { preferences, language } = job;
    try {
      const remaining = job.document.chapters.filter(chapter => !job.audio.has(chapter.index));
      job.session = await this.runtime.create(remaining, preferences, language);
      if (this.isCancelled(job)) { job.session.cancel(); return; }
      job.snapshot.state = "running";
      job.snapshot.startedAt = new Date().toISOString();
      await this.persist(job);
      for (;;) {
        const segment = JSON.parse(job.session.next_segment()) as Segment | null;
        if (!segment) break;
        let mp3: Uint8Array;
        try { mp3 = await this.runtime.synthesize(segment.text, segment.selection); }
        catch (primaryError) {
          if (this.isCancelled(job)) return;
          if (!preferences.secondary) throw primaryError;
          try { job.session.provider_failed(); }
          catch (policyError) { throw new Error(`${String(primaryError)}; ${String(policyError)}`); }
          const fallback = JSON.parse(job.session.next_segment()) as Segment;
          mp3 = await this.runtime.synthesize(fallback.text, fallback.selection);
          job.snapshot.events = [...(job.snapshot.events ?? []), `Secondary voice: ${fallback.selection.engine}`];
        }
        if (this.isCancelled(job)) return;
        const complete = job.session.accept_audio(mp3);
        const url = URL.createObjectURL(new Blob([mp3.slice().buffer], { type: "audio/mpeg" }));
        const manifest = job.chunks.get(segment.chapter) ?? { jobId: job.snapshot.jobId, chapterIndex: segment.chapter, baseUrl: "", chunks: [] };
        manifest.chunks.push({ index: manifest.chunks.length, file: `${segment.index}.mp3`, url, text: segment.text });
        job.chunks.set(segment.chapter, manifest);
        job.snapshot.completedSegments = segment.index + 1;
        job.snapshot.totalSegments = segment.total;
        job.snapshot.progressPercent = 100 * (segment.index + 1) / segment.total;
        const chapter = job.snapshot.chapterProgress?.find(c => c.index === segment.chapter);
        if (chapter) chapter.status = complete ? "completed" : "processing";
        if (complete) {
          const audio = job.session.chapter_audio();
          const blob = new Blob([audio.slice().buffer], { type: "audio/mpeg" });
          const name = `chapter-${segment.chapter + 1}.mp3`;
          job.audio.set(segment.chapter, { chapterIndex: segment.chapter, name, blob });
          // Commit completed audio and its identity before advertising the chapter.
          await this.persist(job);
          if (this.isCancelled(job)) return;
          const output = URL.createObjectURL(blob);
          if (chapter) chapter.downloadUrl = output;
          job.snapshot.outputs?.push({ name: `chapter-${segment.chapter + 1}.mp3`, url: output, sizeBytes: audio.length });
          job.snapshot.chaptersCompleted = (job.snapshot.chaptersCompleted ?? 0) + 1;
          await this.persist(job);
        }
      }
      const completedAt = new Date().toISOString();
      await this.persist(job, { state: "finished", completedAt });
      if (!this.isCancelled(job)) {
        job.snapshot.state = "finished";
        job.snapshot.completedAt = completedAt;
      }
    } catch (error) {
      if (!this.isCancelled(job)) { job.snapshot.state = "failed"; job.snapshot.error = String(error); }
      try { await this.persist(job); }
      catch (storageFailure) { job.snapshot.error = String(storageFailure); }
    } finally { job.session?.free?.(); job.session = undefined; }
  }
  async fetch(jobId: string): Promise<JobSnapshot> { await this.ensureRestored(); return structuredClone(this.job(jobId).snapshot); }
  async poll(jobId: string, options: PollOptions = {}): Promise<JobSnapshot> {
    for (;;) {
      if (options.signal?.aborted) throw new DOMException("Aborted", "AbortError");
      const snapshot = await this.fetch(jobId);
      options.onSnapshot?.(snapshot);
      if (terminal(snapshot.state)) return snapshot;
      await new Promise(resolve => setTimeout(resolve, options.intervalMs ?? 100));
    }
  }
  async cancel(jobId: string): Promise<{ status: string }> { await this.ensureRestored(); const job = this.job(jobId); if (terminal(job.snapshot.state)) return { status: job.snapshot.state }; const active = job.snapshot.state === "running"; job.snapshot.state = "cancelled"; job.session?.cancel(); if (active) this.runtime.cancelSynthesis?.(); await this.persist(job); return { status: "cancelled" }; }
  async resume(jobId: string): Promise<{ status: string }> {
    await this.ensureRestored();
    const job = this.job(jobId);
    if (job.snapshot.state === "finished") return { status: "finished" };
    if (!terminal(job.snapshot.state)) return { status: job.snapshot.state };
    await job.done.catch(() => undefined);
    for (const [chapter, manifest] of job.chunks) {
      if (job.audio.has(chapter)) continue;
      for (const chunk of manifest.chunks) URL.revokeObjectURL(chunk.url);
      job.chunks.delete(chapter);
    }
    job.snapshot.state = "queued";
    job.snapshot.error = undefined;
    job.snapshot.completedAt = undefined;
    job.snapshot.completedSegments = 0;
    job.snapshot.totalSegments = undefined;
    job.snapshot.chapterProgress = job.snapshot.chapterProgress?.map(chapter => ({ ...chapter, status: job.audio.has(chapter.index) ? "completed" : "pending" }));
    await this.persist(job);
    job.done = this.queue.then(() => this.execute(job));
    this.queue = job.done.catch(() => undefined);
    return { status: "queued" };
  }
  async getJobFullText(jobId: string): Promise<BookTextDocument> { await this.ensureRestored(); return structuredClone(this.job(jobId).document); }
  async getJobFullTextResult(jobId: string) { return { kind: "ok" as const, document: await this.getJobFullText(jobId) }; }
  async getChapterManifest(jobId: string, index: number): Promise<ChapterStreamManifest | null> { await this.ensureRestored(); return structuredClone(this.job(jobId).chunks.get(index) ?? null); }
  async getRecentJobs() { await this.ensureRestored(); return [...this.jobs.values()].map(j => ({ jobId: j.snapshot.jobId, state: j.snapshot.state, bookTitle: j.snapshot.bookTitle ?? "", fileName: "", hasOutputs: Boolean(j.snapshot.outputs?.length), outputs: structuredClone(j.snapshot.outputs) })); }
  async getResumableJobs() { await this.ensureRestored(); return [...this.jobs.values()].filter(job => ["interrupted", "failed", "cancelled"].includes(job.snapshot.state)).map(job => ({ jobId: job.snapshot.jobId, state: job.snapshot.state, bookTitle: job.snapshot.bookTitle ?? "", fileName: "", savedAt: job.snapshot.startedAt ?? new Date().toISOString(), chaptersCompleted: job.audio.size, chaptersTotal: job.document.chapters.length, engine: job.preferences.primary.engine, voice: job.preferences.primary.model_id ?? job.preferences.primary.voice ?? undefined, language: job.language })); }
  async removeJob(jobId: string): Promise<{ status: string }> { await this.cancel(jobId); const job = this.job(jobId); await job.done.catch(() => undefined); for (const output of job.snapshot.outputs ?? []) URL.revokeObjectURL(output.url); for (const manifest of job.chunks.values()) for (const chunk of manifest.chunks) URL.revokeObjectURL(chunk.url); await this.store.remove(jobId); this.jobs.delete(jobId); return { status: "removed" }; }
  private isCancelled(job: Job): boolean { return job.snapshot.state === "cancelled"; }
  private job(id: string): Job { const job = this.jobs.get(id); if (!job) throw new Error("Browser job not found."); return job; }
}
