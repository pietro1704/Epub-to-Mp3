import { IndexedDBBrowserJobStore, type BrowserJobStore } from './BrowserJobStore';
import type { BrowserConversionJob } from './browser_conversion_job';
import type { JobSnapshot } from '../types/conversion';
import { browserAudioMatches } from './BrowserAudioIdentity';

/** Own durable reconciliation and the live identities rebuilt from committed audio. */
export class BrowserJobRepository {
  private readonly jobs = new Map<string, BrowserConversionJob>();
  private restored?: Promise<void>;
  constructor(private readonly store: BrowserJobStore = new IndexedDBBrowserJobStore()) {}
  ensureRestored(): Promise<void> {
    return (this.restored ??= this.restore());
  }
  private async restore(): Promise<void> {
    for (const saved of await this.store.list()) {
      const snapshot = structuredClone(saved.snapshot);
      if (['running', 'queued', 'cancelling'].includes(snapshot.state))
        snapshot.state = 'interrupted';
      snapshot.outputs = [];
      const job: BrowserConversionJob = {
        snapshot,
        document: saved.document,
        preferences: saved.preferences,
        language: saved.language,
        policyState: saved.policyState,
        listeningPosition: saved.listeningPosition,
        audio: new Map(),
        chunks: new Map(),
        done: Promise.resolve(),
      };
      for (const artifact of saved.audio) {
        if (!(await browserAudioMatches(saved, artifact))) {
          snapshot.state = 'interrupted';
          continue;
        }
        const ranges = artifact.chunks;
        if (
          ranges?.length &&
          (ranges.some(
            (range, index) =>
              range.index !== index ||
              range.byteLength <= 0 ||
              range.byteOffset !==
                (index === 0 ? 0 : ranges[index - 1].byteOffset + ranges[index - 1].byteLength),
          ) ||
            ranges.at(-1)!.byteOffset + ranges.at(-1)!.byteLength !== artifact.blob.size)
        ) {
          snapshot.state = 'interrupted';
          continue;
        }
        job.audio.set(artifact.chapterIndex, artifact);
        const url = URL.createObjectURL(artifact.blob);
        snapshot.outputs.push({ name: artifact.name, url, sizeBytes: artifact.blob.size });
        job.chunks.set(artifact.chapterIndex, {
          jobId: saved.jobId,
          chapterIndex: artifact.chapterIndex,
          baseUrl: '',
          legacyWholeChapter: !ranges?.length,
          chunks: ranges?.length
            ? ranges.map((range) => ({
                index: range.index,
                file: `${range.index}.mp3`,
                text: range.text,
                durationSeconds: range.durationSeconds,
                url: URL.createObjectURL(
                  artifact.blob.slice(
                    range.byteOffset,
                    range.byteOffset + range.byteLength,
                    'audio/mpeg',
                  ),
                ),
              }))
            : [
                {
                  index: 0,
                  file: artifact.name,
                  url,
                  text: Array.from(
                    saved.document.chapters.find(
                      (chapter) => chapter.index === artifact.chapterIndex,
                    )?.text ?? '',
                  )
                    .slice(artifact.textOffset ?? 0)
                    .join(''),
                },
              ],
        });
      }
      snapshot.chaptersCompleted = job.audio.size;
      snapshot.chapterProgress = snapshot.chapterProgress?.map((chapter) => ({
        ...chapter,
        status: job.audio.has(chapter.index) ? 'completed' : 'pending',
        downloadUrl: snapshot.outputs?.find(
          (output) => output.name === `chapter-${chapter.index + 1}.mp3`,
        )?.url,
      }));
      this.jobs.set(saved.jobId, job);
      if (snapshot.state !== saved.snapshot.state) await this.persist(job);
    }
  }
  persist(job: BrowserConversionJob, committedState: Partial<JobSnapshot> = {}): Promise<void> {
    const snapshot = { ...structuredClone(job.snapshot), ...committedState };
    snapshot.outputs = snapshot.outputs?.map((output) => ({ ...output, url: '' }));
    snapshot.chapterProgress = snapshot.chapterProgress?.map((chapter) => ({
      ...chapter,
      downloadUrl: undefined,
    }));
    return this.store.save({
      jobId: snapshot.jobId,
      snapshot,
      document: structuredClone(job.document),
      preferences: structuredClone(job.preferences),
      language: job.language,
      ...(job.listeningPosition
        ? { listeningPosition: structuredClone(job.listeningPosition) }
        : {}),
      ...(job.policyState ? { policyState: job.policyState } : {}),
      audio: [...job.audio.values()],
    });
  }
  get(id: string): BrowserConversionJob {
    const job = this.jobs.get(id);
    if (!job) throw new Error('Browser job not found.');
    return job;
  }
  all(): IterableIterator<BrowserConversionJob> {
    return this.jobs.values();
  }
  async commitNew(job: BrowserConversionJob): Promise<void> {
    await this.persist(job);
    this.jobs.set(job.snapshot.jobId, job);
  }
  async remove(job: BrowserConversionJob): Promise<void> {
    for (const output of job.snapshot.outputs ?? []) URL.revokeObjectURL(output.url);
    for (const manifest of job.chunks.values())
      for (const chunk of manifest.chunks) URL.revokeObjectURL(chunk.url);
    await this.store.remove(job.snapshot.jobId);
    this.jobs.delete(job.snapshot.jobId);
  }
}
