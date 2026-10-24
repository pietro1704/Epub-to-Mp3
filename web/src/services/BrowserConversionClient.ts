import { loadTtsPreferences } from './TtsPreferences';
import type { BrowserJobStore } from './BrowserJobStore';
import {
  platformRuntime,
  type BrowserRuntime,
  type InspectedBook,
} from './BrowserConversionRuntime';
import { BrowserJobRepository } from './BrowserJobRepository';
import { BrowserJobExecution } from './BrowserJobExecution';
import { terminalBrowserJob, type BrowserConversionJob } from './browser_conversion_job';
import type { ConversionClient, PollOptions, UploadResponse } from './ConversionService';
import type {
  BookTextDocument,
  ChapterStreamManifest,
  ConversionFormValues,
  JobSnapshot,
  TtsPreferences,
} from '../types/conversion';

export {
  browserVoiceId,
  browserWasmPaths,
  installedBrowserVoices,
  installBrowserFaber,
  installBrowserModel,
  installFaberArtifacts,
  type FaberInstallerIO,
} from './BrowserModelInstallation';
export { verifyBrowserFaber } from './BrowserModelIntegrity';
export { createBrowserSynthesis, type BrowserRuntime } from './BrowserConversionRuntime';

/** Browser API and input policy; Rust owns segment planning and acceptance. */
export class BrowserConversionClient implements ConversionClient {
  readonly mode = 'embedded' as const;
  private uploads = new Map<string, { file: File; document: InspectedBook }>();
  private readonly repository: BrowserJobRepository;
  private readonly execution: BrowserJobExecution;
  constructor(
    private readonly runtime: BrowserRuntime = platformRuntime,
    store?: BrowserJobStore,
  ) {
    this.repository = new BrowserJobRepository(store);
    this.execution = new BrowserJobExecution(runtime, this.repository);
  }
  async upload(file: File): Promise<UploadResponse> {
    await this.repository.ensureRestored();
    const inspected = await this.runtime.inspect(file);
    const document = {
      ...inspected,
      chapters: inspected.chapters.map((chapter, index) => ({
        ...chapter,
        index,
        charCount: chapter.text.length,
      })),
    };
    const uploadId = crypto.randomUUID();
    this.uploads.set(uploadId, { file, document });
    return {
      uploadId,
      fileName: file.name,
      bookTitle: document.bookTitle,
      bookAuthor: document.bookAuthor,
    };
  }
  async submit(request: ConversionFormValues): Promise<{ jobId: string }> {
    const unsupported = [
      request.sections,
      request.fromChapterToEnd,
      request.fromChapterToChapter,
      request.priority,
    ];
    if (
      unsupported.some(Boolean) ||
      request.footnoteMode !== 'inline' ||
      request.enableCharacterVoices ||
      request.formattingCues ||
      request.multiEngineParallel ||
      request.exportToIphone ||
      request.bitrate ||
      request.sampleRate ||
      request.channels
    ) {
      throw new Error('This browser does not support the selected advanced conversion options.');
    }
    let preferences: TtsPreferences = structuredClone(
      request.tts_preferences ?? loadTtsPreferences(),
    );
    if (
      preferences.primary.engine === 'system' ||
      preferences.primary.engine === 'edge' ||
      preferences.secondary?.engine === 'edge'
    ) {
      throw new Error(
        'Edge is unavailable in this browser. Choose a compatible offline audio model without an online secondary voice.',
      );
    }
    await this.runtime.validateSelection?.(preferences.primary);
    preferences = (await this.runtime.capturePreferences?.(preferences)) ?? preferences;
    await this.repository.ensureRestored();
    let upload = request.uploadId ? this.uploads.get(request.uploadId) : undefined;
    if (!upload && request.file)
      upload = this.uploads.get((await this.upload(request.file)).uploadId);
    if (!upload) throw new Error('Select an EPUB in this browser session.');
    let chapters = upload.document.chapters;
    if (request.chapters?.trim()) {
      const match = /^(\d+)(?:-(\d+))?$/.exec(request.chapters.trim());
      if (!match)
        throw new Error(
          'Browser chapter selection must be a chapter number or inclusive range, for example 1-2.',
        );
      const start = Number(match[1]);
      const end = Number(match[2] ?? match[1]);
      if (start < 1 || end < start || end > chapters.length)
        throw new Error('Invalid chapter range.');
      chapters = chapters.slice(start - 1, end);
    }
    if (!chapters.some((chapter) => chapter.text.trim()))
      throw new Error('Selected chapters contain no readable text.');
    const jobId = crypto.randomUUID();
    const document = { ...upload.document, chapters, jobId };
    const language = request.language ?? upload.document.language ?? 'pt-BR';
    const job: BrowserConversionJob = {
      document,
      preferences,
      language,
      audio: new Map(),
      chunks: new Map(),
      done: Promise.resolve(),
      snapshot: {
        jobId,
        state: 'queued',
        bookTitle: document.bookTitle,
        bookAuthor: document.bookAuthor,
        chaptersTotal: chapters.length,
        chaptersCompleted: 0,
        progressPercent: 0,
        engine: preferences.primary.engine,
        voice: preferences.primary.model_id ?? preferences.primary.voice ?? undefined,
        outputs: [],
        chapterProgress: chapters.map((c) => ({
          index: c.index,
          name: c.name,
          chars: c.charCount,
          status: 'pending',
        })),
      },
    };
    await this.repository.commitNew(job);
    this.execution.enqueue(job);
    return { jobId };
  }
  async fetch(jobId: string): Promise<JobSnapshot> {
    await this.repository.ensureRestored();
    return structuredClone(this.repository.get(jobId).snapshot);
  }
  async poll(jobId: string, options: PollOptions = {}): Promise<JobSnapshot> {
    for (;;) {
      if (options.signal?.aborted) throw new DOMException('Aborted', 'AbortError');
      const snapshot = await this.fetch(jobId);
      options.onSnapshot?.(snapshot);
      if (terminalBrowserJob(snapshot.state)) return snapshot;
      await new Promise((resolve) => setTimeout(resolve, options.intervalMs ?? 100));
    }
  }
  async getNativePlaybackPolicy(
    jobId: string,
  ): Promise<{ language: string; voice: string | null } | null> {
    await this.repository.ensureRestored();
    const job = this.repository.get(jobId);
    if (
      job.snapshot.state !== 'failed' ||
      job.snapshot.errorCategory !== 'tts_provider' ||
      (job.preferences.policy_version !== 2 && job.preferences.secondary?.engine !== 'system')
    )
      return null;
    return {
      language: job.language,
      voice:
        job.preferences.secondary?.engine === 'system' ? job.preferences.secondary.voice : null,
    };
  }
  async getJobFullText(jobId: string): Promise<BookTextDocument> {
    await this.repository.ensureRestored();
    return structuredClone(this.repository.get(jobId).document);
  }
  async getJobFullTextResult(jobId: string) {
    return { kind: 'ok' as const, document: await this.getJobFullText(jobId) };
  }
  async getChapterManifest(jobId: string, index: number): Promise<ChapterStreamManifest | null> {
    await this.repository.ensureRestored();
    return structuredClone(this.repository.get(jobId).chunks.get(index) ?? null);
  }
  async getRecentJobs() {
    await this.repository.ensureRestored();
    return [...this.repository.all()].map((j) => ({
      jobId: j.snapshot.jobId,
      state: j.snapshot.state,
      bookTitle: j.snapshot.bookTitle ?? '',
      fileName: '',
      hasOutputs: Boolean(j.snapshot.outputs?.length),
      outputs: structuredClone(j.snapshot.outputs),
    }));
  }
  async getResumableJobs() {
    await this.repository.ensureRestored();
    return [...this.repository.all()]
      .filter((job) => ['interrupted', 'failed', 'cancelled'].includes(job.snapshot.state))
      .map((job) => ({
        jobId: job.snapshot.jobId,
        state: job.snapshot.state,
        bookTitle: job.snapshot.bookTitle ?? '',
        fileName: '',
        savedAt: job.snapshot.startedAt ?? new Date().toISOString(),
        chaptersCompleted: job.audio.size,
        chaptersTotal: job.document.chapters.length,
        engine: job.preferences.primary.engine,
        voice: job.preferences.primary.model_id ?? job.preferences.primary.voice ?? undefined,
        language: job.language,
      }));
  }
  async cancel(jobId: string): Promise<{ status: string }> {
    return this.execution.cancel(jobId);
  }
  async listenFrom(jobId: string, chapter: number, textOffset = 0): Promise<void> {
    return this.execution.listenFrom(jobId, chapter, textOffset);
  }
  async playbackFeedback(
    jobId: string,
    chapter: number,
    remaining: number,
    rate: number,
  ): Promise<void> {
    return this.execution.playbackFeedback(jobId, chapter, remaining, rate);
  }
  async resume(jobId: string): Promise<{ status: string }> {
    return this.execution.resume(jobId);
  }
  async removeJob(jobId: string): Promise<{ status: string }> {
    await this.cancel(jobId);
    const job = this.repository.get(jobId);
    await job.done.catch(() => undefined);
    await this.repository.remove(job);
    return { status: 'removed' };
  }
}
