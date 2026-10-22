import { API_BASE_URL } from '../config';
import {
  ConversionFormValues,
  JobSnapshot,
  RecentJobEntry,
  ChapterStreamManifest,
  BookTextDocument,
} from '../types/conversion';
import type {
  ConversionClient,
  PollOptions,
  ResumableJob,
  RestartOptions,
  FullTextResult,
  UploadResponse,
} from './conversion_client_contract';
import { buildFormData } from './http_conversion_form';
import {
  normalizeErrorMessage,
  parseResponse,
  normalizeAssetUrl,
} from './http_conversion_response';
import { supportsEventStream, pollWithEventSource, pollWithHttp } from './http_event_stream';

export class HttpConversionClient implements ConversionClient {
  readonly mode = 'http' as const;
  private resumableEndpointAvailable = true;

  constructor(private readonly baseUrl: string = API_BASE_URL) {}

  private resolve(path: string): string {
    const normalizedBase = this.baseUrl.replace(/\/$/, '');
    const normalizedPath = path.startsWith('/') ? path : `/${path}`;
    if (!normalizedBase) {
      return normalizeAssetUrl('', normalizedPath);
    }

    if (/^https?:\/\//i.test(normalizedBase)) {
      if (normalizedBase.endsWith('/api') && normalizedPath.startsWith('/api')) {
        return `${normalizedBase}${normalizedPath.substring(4)}`;
      }
      return `${normalizedBase}${normalizedPath}`;
    }

    if (normalizedBase.endsWith('/api') && normalizedPath.startsWith('/api')) {
      return `${normalizedBase}${normalizedPath.substring(4)}`;
    }

    return normalizeAssetUrl('', `${normalizedBase}${normalizedPath}`);
  }

  private normalizeSnapshot(snapshot: JobSnapshot): JobSnapshot {
    const normalized: JobSnapshot = { ...snapshot };

    if (Array.isArray(snapshot.outputs)) {
      normalized.outputs = snapshot.outputs.map((asset) => ({
        ...asset,
        url: normalizeAssetUrl(this.baseUrl, asset.url),
      }));
    }

    if (normalized.coverUrl) {
      normalized.coverUrl = normalizeAssetUrl(this.baseUrl, normalized.coverUrl);
    }

    if (Array.isArray(normalized.chapterProgress)) {
      normalized.chapterProgress = normalized.chapterProgress.map((chapter) => ({
        ...chapter,
        downloadUrl: chapter.downloadUrl
          ? normalizeAssetUrl(this.baseUrl, chapter.downloadUrl)
          : undefined,
      }));
    }

    return normalized;
  }

  async submit(request: ConversionFormValues): Promise<{ jobId: string }> {
    const response = await fetch(this.resolve('/api/convert'), {
      method: 'POST',
      body: buildFormData(request),
    });

    // Auto-recover: if the upload expired on the server but we still have the
    // original local file path (desktop app), re-register it and retry once.
    if (!response.ok && response.status === 404 && request.localPath && request.uploadId) {
      const body = await response.text();
      if (body.includes('Upload not found') || body.includes('expired')) {
        try {
          const reReg = await fetch(this.resolve('/api/uploads/local'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ path: request.localPath }),
          });
          if (reReg.ok) {
            const newUpload: UploadResponse = await reReg.json();
            const retryResp = await fetch(this.resolve('/api/convert'), {
              method: 'POST',
              body: buildFormData({ ...request, uploadId: newUpload.uploadId }),
            });
            return parseResponse<{ jobId: string }>(retryResp);
          }
        } catch {
          // Re-registration failed; fall through to original error below
        }
        throw new Error(normalizeErrorMessage(response.status, response.statusText, body));
      }
    }

    return parseResponse<{ jobId: string }>(response);
  }

  async fetch(jobId: string, signal?: AbortSignal): Promise<JobSnapshot> {
    const response = await fetch(this.resolve(`/api/jobs/${encodeURIComponent(jobId)}`), {
      method: 'GET',
      signal,
    });
    if (response.status === 404) {
      throw new Error(`Job ${jobId} not found (404)`);
    }
    if (!response.ok) {
      const text = await response.text();
      const error = new Error(
        normalizeErrorMessage(response.status, response.statusText, text),
      ) as Error & { status?: number };
      error.status = response.status;
      throw error;
    }
    const snapshot = (await response.json()) as JobSnapshot;
    return this.normalizeSnapshot(snapshot);
  }

  async poll(jobId: string, options: PollOptions = {}): Promise<JobSnapshot> {
    if (supportsEventStream()) {
      const streamed = await pollWithEventSource(
        {
          fetch: this.fetch.bind(this),
          resolve: this.resolve.bind(this),
          normalizeSnapshot: this.normalizeSnapshot.bind(this),
        },
        jobId,
        options,
      );
      if (streamed) {
        return streamed;
      }
    }
    options.onStreamStatus?.('fallback');
    return pollWithHttp(
      {
        fetch: this.fetch.bind(this),
        resolve: this.resolve.bind(this),
        normalizeSnapshot: this.normalizeSnapshot.bind(this),
      },
      jobId,
      options,
    );
  }

  async cancel(jobId: string): Promise<{ status: string }> {
    const response = await fetch(this.resolve(`/api/jobs/${encodeURIComponent(jobId)}/cancel`), {
      method: 'POST',
    });
    return parseResponse<{ status: string }>(response);
  }

  async resume(jobId: string): Promise<{ status: string }> {
    const response = await fetch(this.resolve(`/api/jobs/${encodeURIComponent(jobId)}/resume`), {
      method: 'POST',
    });
    return parseResponse<{ status: string }>(response);
  }

  async removeJob(jobId: string): Promise<{ status: string }> {
    const response = await fetch(this.resolve(`/api/jobs/${encodeURIComponent(jobId)}`), {
      method: 'DELETE',
    });
    return parseResponse<{ status: string }>(response);
  }

  async restartBackend(options?: RestartOptions): Promise<{ status: string }> {
    const response = await fetch(this.resolve('/api/system/restart'), {
      method: 'POST',
      headers: options ? { 'Content-Type': 'application/json' } : undefined,
      body: options ? JSON.stringify(options) : undefined,
    });
    return parseResponse<{ status: string }>(response);
  }

  async upload(file: File): Promise<UploadResponse> {
    const formData = new FormData();
    formData.append('file', file);
    const response = await fetch(this.resolve('/api/uploads'), {
      method: 'POST',
      body: formData,
    });
    const payload = await parseResponse<UploadResponse>(response);
    if (payload.coverUrl) {
      payload.coverUrl = normalizeAssetUrl(this.baseUrl, payload.coverUrl);
    }
    return payload;
  }

  async getResumableJobs(): Promise<ResumableJob[] | null> {
    if (!this.resumableEndpointAvailable) {
      return null;
    }
    try {
      const response = await fetch(this.resolve('/api/jobs/resumable'), {
        method: 'GET',
      });
      if (response.status === 404) {
        this.resumableEndpointAvailable = false;
        return null;
      }
      const data = await parseResponse<{
        resumable_jobs: ResumableJob[];
        count: number;
      }>(response);
      return data.resumable_jobs || [];
    } catch (error) {
      if (error instanceof Error && error.message.includes('404')) {
        this.resumableEndpointAvailable = false;
        return null;
      }
      console.warn('[ConversionClient] Failed to fetch resumable jobs:', error);
      return null;
    }
  }

  async getRecentJobs(): Promise<RecentJobEntry[] | null> {
    const response = await fetch(this.resolve('/api/jobs/recent'), {
      method: 'GET',
    });
    if (!response.ok) {
      return null;
    }
    const payload = await response.json();
    if (!payload || !Array.isArray(payload.jobs)) {
      return null;
    }
    return payload.jobs as RecentJobEntry[];
  }

  async getChapterManifest(
    jobId: string,
    chapterIndex: number,
  ): Promise<ChapterStreamManifest | null> {
    const url = this.resolve(
      `/api/streams/${encodeURIComponent(jobId)}/chapters/${encodeURIComponent(chapterIndex)}`,
    );
    try {
      const response = await fetch(url, { method: 'GET' });
      if (!response.ok) {
        return null;
      }
      const payload = (await response.json()) as ChapterStreamManifest;
      if (!payload || !Array.isArray(payload.chunks)) {
        return null;
      }
      const normalizedChunks = payload.chunks
        .map((chunk, idx) => ({
          ...chunk,
          index:
            typeof chunk.index === 'number' && Number.isFinite(chunk.index) ? chunk.index : idx,
          url: chunk.url ? this.resolve(chunk.url) : chunk.url,
        }))
        .sort((a, b) => a.index - b.index);
      return { ...payload, chunks: normalizedChunks };
    } catch (error) {
      console.warn('[ConversionClient] Failed to fetch stream manifest:', error);
      return null;
    }
  }

  async getJobFullText(jobId: string): Promise<BookTextDocument | null> {
    const result = await this.getJobFullTextResult(jobId);
    return result.kind === 'ok' ? result.document : null;
  }

  async getJobFullTextResult(jobId: string): Promise<FullTextResult> {
    const url = this.resolve(`/api/jobs/${encodeURIComponent(jobId)}/fulltext`);
    try {
      const response = await fetch(url, { method: 'GET' });
      if (response.status === 503) {
        return { kind: 'pending', status: 503 };
      }
      if (response.status === 404) {
        return { kind: 'missing', status: 404 };
      }
      if (response.status === 422) {
        return { kind: 'unprocessable', status: 422 };
      }
      if (!response.ok) {
        return { kind: 'error', status: response.status };
      }
      const payload = (await response.json()) as BookTextDocument;
      if (!payload || !Array.isArray(payload.chapters)) {
        return { kind: 'error', status: response.status };
      }
      if (payload.chapters.length === 0) {
        return { kind: 'pending', status: 200 };
      }
      const document: BookTextDocument = {
        ...payload,
        chapters: payload.chapters.map((chapter, index) => ({
          index:
            typeof chapter.index === 'number' && Number.isFinite(chapter.index)
              ? chapter.index
              : index,
          name: chapter.name || `Chapter ${index}`,
          text: chapter.text || '',
          html: typeof chapter.html === 'string' ? chapter.html : undefined,
          css: typeof chapter.css === 'string' ? chapter.css : undefined,
          charCount:
            typeof chapter.charCount === 'number' && Number.isFinite(chapter.charCount)
              ? chapter.charCount
              : (chapter.text || '').length,
        })),
      };
      return { kind: 'ok', document };
    } catch (error) {
      console.warn('[ConversionClient] Failed to fetch full text:', error);
      return { kind: 'network-error' };
    }
  }
}
