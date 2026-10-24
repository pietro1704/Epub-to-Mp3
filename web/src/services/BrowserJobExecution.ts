import { BrowserTtsPreparationError } from './BrowserTtsFailure';
import type {
  BrowserRuntime,
  BrowserSegment,
  BrowserSynthesis,
  BrowserAudioReceipt,
} from './BrowserConversionRuntime';
import { BrowserJobRepository } from './BrowserJobRepository';
import { sealBrowserAudio } from './BrowserAudioIdentity';
import type { StoredBrowserAudio } from './BrowserJobStore';
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
      // Keep every source chapter addressable if a running manual job becomes listening.
      const remaining = job.document.chapters;
      job.session = job.policyState
        ? await this.runtime.create(remaining, preferences, language, job.policyState)
        : await this.runtime.create(remaining, preferences, language);
      if (isBrowserJobCancelled(job)) {
        job.session.cancel();
        return;
      }
      if (job.listeningPosition) {
        if (!job.session.set_listening_position_json_v2)
          throw new Error('The converter lacks version 2 listening control');
        job.session.set_listening_position_json_v2(JSON.stringify(job.listeningPosition));
      }
      job.snapshot.state = 'running';
      job.snapshot.startedAt = new Date().toISOString();
      await this.repository.persist(job);
      const receipts = new Map<number, BrowserAudioReceipt[]>();
      const ranges = new Map<number, NonNullable<StoredBrowserAudio['chunks']>>();
      let receiptEpoch = job.listeningEpoch;
      for (;;) {
        if (receiptEpoch !== job.listeningEpoch) {
          receipts.clear();
          ranges.clear();
          receiptEpoch = job.listeningEpoch;
        }
        const segment = JSON.parse(job.session.next_segment()) as BrowserSegment | null;
        if (!segment) {
          const finishingEpoch = job.listeningEpoch;
          const completedAt = new Date().toISOString();
          await this.repository.persist(job, { state: 'finished', completedAt });
          if (isBrowserJobCancelled(job)) return;
          if (finishingEpoch !== job.listeningEpoch) {
            await this.repository.persist(job);
            continue;
          }
          job.snapshot.state = 'finished';
          job.snapshot.completedAt = completedAt;
          return;
        }
        if (isBrowserJobCancelled(job)) return;
        if ('waiting' in segment) {
          await new Promise((resolve) => setTimeout(resolve, 100));
          continue;
        }
        const expectedOffset =
          job.listeningPosition?.chapter_index === segment.chapter
            ? job.listeningPosition.text_offset
            : 0;
        if (
          job.audio.has(segment.chapter) &&
          (job.audio.get(segment.chapter)?.textOffset ?? 0) !== expectedOffset
        )
          this.retireAudio(job, segment.chapter);
        if (job.audio.has(segment.chapter) && job.session.skip_cached_chapter_v2) {
          job.session.skip_cached_chapter_v2(segment.chapter);
          continue;
        }
        const epoch = job.listeningEpoch;
        const started = performance.now();
        let synthesis: Uint8Array | BrowserSynthesis;
        try {
          synthesis = await this.runtime.synthesize(segment.text, segment.selection);
        } catch (primaryError) {
          if (isBrowserJobCancelled(job)) return;
          if (epoch !== job.listeningEpoch) continue;
          job.snapshot.errorCategory = 'tts_provider';
          if (!preferences.secondary || preferences.secondary.engine === 'system')
            throw primaryError;
          try {
            job.session.provider_failed();
          } catch (policyError) {
            throw new Error(`${String(primaryError)}; ${String(policyError)}`);
          }
          const fallback = JSON.parse(job.session.next_segment()) as BrowserSegment;
          try {
            synthesis = await this.runtime.synthesize(fallback.text, fallback.selection);
          } catch (fallbackError) {
            if (isBrowserJobCancelled(job)) return;
            if (epoch !== job.listeningEpoch) continue;
            throw fallbackError;
          }
          job.snapshot.events = [
            ...(job.snapshot.events ?? []),
            `Secondary voice: ${fallback.selection.engine}`,
          ];
        }
        if (isBrowserJobCancelled(job)) return;
        if (epoch !== job.listeningEpoch) continue;
        job.session.observe_generation_v2?.(
          (performance.now() - started) / 1000,
          Array.from(segment.text).length,
        );
        const mp3 = synthesis instanceof Uint8Array ? synthesis : synthesis.audio;
        const receipt: BrowserAudioReceipt | undefined =
          synthesis instanceof Uint8Array
            ? undefined
            : {
                version: 2,
                session_id: segment.session_id ?? '',
                source_index: segment.chapter,
                segment_index: segment.index,
                format: synthesis.format,
                identity: synthesis.identity,
              };
        const complete =
          synthesis instanceof Uint8Array
            ? job.session.accept_audio(mp3)
            : (() => {
                if (!job.session.accept_audio_v2)
                  throw new Error('The embedded converter lacks version 2 audio receipts');
                return job.session.accept_audio_v2(mp3, JSON.stringify(receipt));
              })();
        if (receipt)
          receipts.set(segment.chapter, [...(receipts.get(segment.chapter) ?? []), receipt]);
        job.policyState = job.session.policy_state_json?.();
        const url = URL.createObjectURL(new Blob([mp3.slice().buffer], { type: 'audio/mpeg' }));
        const manifest = job.chunks.get(segment.chapter) ?? {
          jobId: job.snapshot.jobId,
          chapterIndex: segment.chapter,
          baseUrl: '',
          chunks: [],
        };
        manifest.chunks.push({
          durationSeconds: job.session.audio_duration_seconds_v2?.(mp3),
          index: manifest.chunks.length,
          file: `${segment.index}.mp3`,
          url,
          text: segment.text,
        });
        job.chunks.set(segment.chapter, manifest);
        const chapterRanges = ranges.get(segment.chapter) ?? [];
        const previousRange = chapterRanges.at(-1);
        chapterRanges.push({
          index: manifest.chunks.length - 1,
          text: segment.text,
          durationSeconds: manifest.chunks.at(-1)?.durationSeconds,
          byteOffset: previousRange ? previousRange.byteOffset + previousRange.byteLength : 0,
          byteLength: mp3.length,
        });
        ranges.set(segment.chapter, chapterRanges);
        job.snapshot.completedSegments = segment.index + 1;
        job.snapshot.totalSegments = segment.total;
        job.snapshot.progressPercent = (100 * (segment.index + 1)) / segment.total;
        const chapter = job.snapshot.chapterProgress?.find((c) => c.index === segment.chapter);
        if (chapter) chapter.status = complete ? 'completed' : 'processing';
        if (complete) {
          const audio = job.session.chapter_audio();
          const blob = new Blob([audio.slice().buffer], { type: 'audio/mpeg' });
          const name = `chapter-${segment.chapter + 1}.mp3`;
          const artifact = {
            chunks: structuredClone(chapterRanges),
            textOffset:
              job.listeningPosition?.chapter_index === segment.chapter
                ? job.listeningPosition.text_offset
                : 0,
            chapterIndex: segment.chapter,
            name,
            blob,
            ...(receipts.has(segment.chapter)
              ? { ttsReceipts: receipts.get(segment.chapter) }
              : {}),
          };
          const cacheIdentity = await sealBrowserAudio(job, artifact);
          if (isBrowserJobCancelled(job)) return;
          if (epoch !== job.listeningEpoch) continue;
          job.audio.set(segment.chapter, {
            ...artifact,
            ...(cacheIdentity ? { cacheIdentity } : {}),
          });
          // Commit completed audio and its identity before advertising the chapter.
          await this.repository.persist(job);
          if (isBrowserJobCancelled(job)) return;
          if (epoch !== job.listeningEpoch) continue;
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
    } catch (error) {
      if (!isBrowserJobCancelled(job)) {
        if (error instanceof BrowserTtsPreparationError)
          job.snapshot.errorCategory = 'tts_provider';
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

  async listenFrom(jobId: string, chapter: number, textOffset = 0): Promise<void> {
    await this.repository.ensureRestored();
    const job = this.repository.get(jobId);
    const source = job.document.chapters.find((candidate) => candidate.index === chapter);
    if (
      !source ||
      !Number.isSafeInteger(textOffset) ||
      textOffset < 0 ||
      textOffset >= Array.from(source.text).length
    )
      throw new Error('Invalid listening text position');
    if (
      job.audio.has(chapter) &&
      (job.audio.get(chapter)?.textOffset ?? 0) === textOffset &&
      !job.listeningPosition
    )
      return;
    const position = { version: 2 as const, chapter_index: chapter, text_offset: textOffset };
    if (job.session) {
      if (!job.session.set_listening_position_json_v2)
        throw new Error('The converter lacks version 2 listening control');
      job.session.set_listening_position_json_v2(JSON.stringify(position));
    }
    job.listeningPosition = position;
    job.listeningEpoch = (job.listeningEpoch ?? 0) + 1;
    for (const [index, artifact] of job.audio) {
      if ((artifact.textOffset ?? 0) !== (index === chapter ? textOffset : 0))
        this.retireAudio(job, index);
    }
    for (const [index, manifest] of job.chunks) {
      if (job.audio.has(index)) continue;
      for (const chunk of manifest.chunks) URL.revokeObjectURL(chunk.url);
      job.chunks.delete(index);
    }
    if (job.snapshot.state === 'running') this.runtime.cancelSynthesis?.();
    await this.repository.persist(job);
    if (job.snapshot.state === 'finished') job.snapshot.state = 'interrupted';
    if (terminalBrowserJob(job.snapshot.state)) await this.resume(jobId);
  }

  private retireAudio(job: BrowserConversionJob, chapter: number): void {
    job.audio.delete(chapter);
    job.snapshot.outputs = job.snapshot.outputs?.filter((output) => {
      if (output.name !== `chapter-${chapter + 1}.mp3`) return true;
      URL.revokeObjectURL(output.url);
      return false;
    });
    const manifest = job.chunks.get(chapter);
    for (const chunk of manifest?.chunks ?? []) URL.revokeObjectURL(chunk.url);
    job.chunks.delete(chapter);
    const state = job.snapshot.chapterProgress?.find((entry) => entry.index === chapter);
    if (state) {
      state.status = 'pending';
      state.downloadUrl = undefined;
    }
    job.snapshot.chaptersCompleted = job.audio.size;
  }

  async playbackFeedback(
    jobId: string,
    chapter: number,
    remaining: number,
    rate: number,
  ): Promise<void> {
    await this.repository.ensureRestored();
    const job = this.repository.get(jobId);
    if (!job.listeningPosition || !job.session?.playback_feedback_json_v2) return;
    if (job.listeningPosition.chapter_index !== chapter) return;
    const generation = Number(job.session.listening_generation_v2?.() ?? 0);
    job.session.playback_feedback_json_v2(
      JSON.stringify({
        version: 2,
        generation,
        chapter_index: chapter,
        remaining_audio_seconds: remaining,
        playback_rate: rate,
      }),
    );
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
