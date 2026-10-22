import type { BrowserRuntime, BrowserSegment } from './BrowserConversionRuntime';
import { BrowserJobRepository } from './BrowserJobRepository';
import {
  isBrowserJobCancelled,
  terminalBrowserJob,
  type BrowserConversionJob,
} from './browser_conversion_job';

/** Own the serial runtime session lease, publication ordering and cancellation. */
export class BrowserJobExecution {
  private queue: Promise<void> = Promise.resolve();
  constructor(
    private readonly runtime: BrowserRuntime,
    private readonly repository: BrowserJobRepository,
  ) {}
  enqueue(job: BrowserConversionJob): void {
    job.done = this.queue.then(() => this.execute(job));
    this.queue = job.done.catch(() => undefined);
  }
  private async execute(job: BrowserConversionJob): Promise<void> {
    if (isBrowserJobCancelled(job)) return;
    const { preferences, language } = job;
    try {
      const remaining = job.document.chapters.filter((chapter) => !job.audio.has(chapter.index));
      job.session = await this.runtime.create(remaining, preferences, language);
      if (isBrowserJobCancelled(job)) {
        job.session.cancel();
        return;
      }
      job.snapshot.state = 'running';
      job.snapshot.startedAt = new Date().toISOString();
      await this.repository.persist(job);
      for (;;) {
        const segment = JSON.parse(job.session.next_segment()) as BrowserSegment | null;
        if (!segment) break;
        let mp3: Uint8Array;
        try {
          mp3 = await this.runtime.synthesize(segment.text, segment.selection);
        } catch (primaryError) {
          if (isBrowserJobCancelled(job)) return;
          job.snapshot.errorCategory = 'tts_provider';
          if (!preferences.secondary || preferences.secondary.engine === 'system')
            throw primaryError;
          try {
            job.session.provider_failed();
          } catch (policyError) {
            throw new Error(`${String(primaryError)}; ${String(policyError)}`);
          }
          const fallback = JSON.parse(job.session.next_segment()) as BrowserSegment;
          mp3 = await this.runtime.synthesize(fallback.text, fallback.selection);
          job.snapshot.events = [
            ...(job.snapshot.events ?? []),
            `Secondary voice: ${fallback.selection.engine}`,
          ];
        }
        if (isBrowserJobCancelled(job)) return;
        const complete = job.session.accept_audio(mp3);
        const url = URL.createObjectURL(new Blob([mp3.slice().buffer], { type: 'audio/mpeg' }));
        const manifest = job.chunks.get(segment.chapter) ?? {
          jobId: job.snapshot.jobId,
          chapterIndex: segment.chapter,
          baseUrl: '',
          chunks: [],
        };
        manifest.chunks.push({
          index: manifest.chunks.length,
          file: `${segment.index}.mp3`,
          url,
          text: segment.text,
        });
        job.chunks.set(segment.chapter, manifest);
        job.snapshot.completedSegments = segment.index + 1;
        job.snapshot.totalSegments = segment.total;
        job.snapshot.progressPercent = (100 * (segment.index + 1)) / segment.total;
        const chapter = job.snapshot.chapterProgress?.find((c) => c.index === segment.chapter);
        if (chapter) chapter.status = complete ? 'completed' : 'processing';
        if (complete) {
          const audio = job.session.chapter_audio();
          const blob = new Blob([audio.slice().buffer], { type: 'audio/mpeg' });
          const name = `chapter-${segment.chapter + 1}.mp3`;
          job.audio.set(segment.chapter, { chapterIndex: segment.chapter, name, blob });
          // Commit completed audio and its identity before advertising the chapter.
          await this.repository.persist(job);
          if (isBrowserJobCancelled(job)) return;
          const output = URL.createObjectURL(blob);
          if (chapter) chapter.downloadUrl = output;
          job.snapshot.outputs?.push({
            name: `chapter-${segment.chapter + 1}.mp3`,
            url: output,
            sizeBytes: audio.length,
          });
          job.snapshot.chaptersCompleted = (job.snapshot.chaptersCompleted ?? 0) + 1;
          await this.repository.persist(job);
        }
      }
      const completedAt = new Date().toISOString();
      await this.repository.persist(job, { state: 'finished', completedAt });
      if (!isBrowserJobCancelled(job)) {
        job.snapshot.state = 'finished';
        job.snapshot.completedAt = completedAt;
      }
    } catch (error) {
      if (!isBrowserJobCancelled(job)) {
        job.snapshot.state = 'failed';
        job.snapshot.error = String(error);
      }
      try {
        await this.repository.persist(job);
      } catch (storageFailure) {
        job.snapshot.error = String(storageFailure);
      }
    } finally {
      job.session?.free?.();
      job.session = undefined;
    }
  }
  async cancel(jobId: string): Promise<{ status: string }> {
    await this.repository.ensureRestored();
    const job = this.repository.get(jobId);
    if (terminalBrowserJob(job.snapshot.state)) return { status: job.snapshot.state };
    const active = job.snapshot.state === 'running';
    job.snapshot.state = 'cancelled';
    job.session?.cancel();
    if (active) this.runtime.cancelSynthesis?.();
    await this.repository.persist(job);
    return { status: 'cancelled' };
  }
  async resume(jobId: string): Promise<{ status: string }> {
    await this.repository.ensureRestored();
    const job = this.repository.get(jobId);
    if (job.snapshot.state === 'finished') return { status: 'finished' };
    if (!terminalBrowserJob(job.snapshot.state)) return { status: job.snapshot.state };
    await job.done.catch(() => undefined);
    for (const [chapter, manifest] of job.chunks) {
      if (job.audio.has(chapter)) continue;
      for (const chunk of manifest.chunks) URL.revokeObjectURL(chunk.url);
      job.chunks.delete(chapter);
    }
    job.snapshot.state = 'queued';
    job.snapshot.error = undefined;
    job.snapshot.errorCategory = undefined;
    job.snapshot.completedAt = undefined;
    job.snapshot.completedSegments = 0;
    job.snapshot.totalSegments = undefined;
    job.snapshot.chapterProgress = job.snapshot.chapterProgress?.map((chapter) => ({
      ...chapter,
      status: job.audio.has(chapter.index) ? 'completed' : 'pending',
    }));
    await this.repository.persist(job);
    this.enqueue(job);
    return { status: 'queued' };
  }
}
