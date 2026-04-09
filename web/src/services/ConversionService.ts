import { API_BASE_URL, ENABLE_SSE, POLL_INTERVAL_MS } from "../config";
import {
  ConversionFormValues,
  JobSnapshot,
  RecentJobEntry,
  ChapterStreamManifest,
  BookTextDocument,
} from "../types/conversion";

export interface PollOptions {
  intervalMs?: number;
  signal?: AbortSignal;
  onSnapshot?: (snapshot: JobSnapshot) => void;
}

export interface ResumableJob {
  jobId: string;
  state: string;
  bookTitle: string;
  fileName: string;
  savedAt: string;
  chaptersCompleted?: number;
  chaptersTotal?: number;
  engine?: string;
  voice?: string;
  language?: string;
  formattingCues?: boolean;
  uiLanguage?: string;
}

export interface RestartOptions {
  keep_cache?: boolean;
  keep_finished?: boolean;
}

export interface ConversionClient {
  submit(request: ConversionFormValues): Promise<{ jobId: string }>;
  fetch(jobId: string, signal?: AbortSignal): Promise<JobSnapshot>;
  poll(jobId: string, options?: PollOptions): Promise<JobSnapshot>;
  getResumableJobs?(): Promise<ResumableJob[] | null>;
  getRecentJobs?(): Promise<RecentJobEntry[] | null>;
  getChapterManifest?(
    jobId: string,
    chapterIndex: number,
  ): Promise<ChapterStreamManifest | null>;
  getJobFullText?(jobId: string): Promise<BookTextDocument | null>;
  cancel?(jobId: string): Promise<{ status: string }>;
  resume?(jobId: string): Promise<{ status: string }>;
  removeJob?(jobId: string): Promise<{ status: string }>;
  upload?(file: File): Promise<UploadResponse>;
  restartBackend?(options?: RestartOptions): Promise<{ status: string }>;
}

export interface UploadResponse {
  uploadId: string;
  fileName: string;
  bookTitle?: string;
  bookAuthor?: string;
  coverUrl?: string;
  coverMimeType?: string;
}

function buildFormData(values: ConversionFormValues): FormData {
  const formData = new FormData();
  const uploadId = values.uploadId?.trim();
  const hasUploadId = Boolean(uploadId);
  if (uploadId) {
    formData.append("upload_id", uploadId);
  }
  // Never re-send the file if an uploadId already exists
  if (values.file && !hasUploadId) {
    formData.append("file", values.file);
  }
  formData.append("engine", values.engine);
  if (values.voice) {
    formData.append("voice", values.voice);
  }
  if (values.model) {
    formData.append("model", values.model);
  }
  if (values.chapters) {
    formData.append("chapters", values.chapters);
  }
  if (values.sections) {
    formData.append("sections", values.sections);
  }
  if (values.fromChapterToEnd) {
    formData.append("fromChapterToEnd", values.fromChapterToEnd);
  }
  if (values.fromChapterToChapter) {
    formData.append("fromChapterToChapter", values.fromChapterToChapter);
  }
  if (values.priority) {
    formData.append("priority", values.priority);
  }
  if (values.footnoteMode) {
    formData.append("footnote_mode", values.footnoteMode);
  }
  if (values.language) {
    formData.append("language", values.language);
  }
  if (typeof values.formattingCues === "boolean") {
    formData.append("formatting_cues", values.formattingCues ? "on" : "off");
  }
  if (values.noParallel) {
    formData.append("no_parallel", "on");
  }
  if (values.multiEngineParallel) {
    formData.append("multi_engine_parallel", "on");
  }
  if (typeof values.maxPerformance === "boolean") {
    formData.append("max_performance", values.maxPerformance ? "on" : "off");
  }
  if (
    typeof values.parallelSlots === "number" &&
    Number.isFinite(values.parallelSlots)
  ) {
    formData.append("parallel_slots", String(values.parallelSlots));
  }
  if (
    typeof values.chapterStallSeconds === "number" &&
    Number.isFinite(values.chapterStallSeconds)
  ) {
    formData.append(
      "chapter_stall_seconds",
      String(values.chapterStallSeconds),
    );
  }
  if (values.edgeNetworkTier) {
    formData.append("edge_network_tier", values.edgeNetworkTier);
  }
  if (
    typeof values.edgeChunkChars === "number" &&
    Number.isFinite(values.edgeChunkChars)
  ) {
    formData.append("edge_chunk_chars", String(values.edgeChunkChars));
  }
  if (
    typeof values.edgeMaxSegmentSeconds === "number" &&
    Number.isFinite(values.edgeMaxSegmentSeconds)
  ) {
    formData.append(
      "edge_max_segment_seconds",
      String(values.edgeMaxSegmentSeconds),
    );
  }
  if (typeof values.edgeEnableParallel === "boolean") {
    formData.append(
      "edge_enable_parallel",
      values.edgeEnableParallel ? "on" : "off",
    );
  }
  if (typeof values.edgeAutoTune === "boolean") {
    formData.append("edge_auto_tune", values.edgeAutoTune ? "on" : "off");
  }
  if (typeof values.edgeStableMode === "boolean") {
    formData.append("edge_stable_mode", values.edgeStableMode ? "on" : "off");
  }
  if (
    typeof values.coquiChunkChars === "number" &&
    Number.isFinite(values.coquiChunkChars)
  ) {
    formData.append("coqui_chunk_chars", String(values.coquiChunkChars));
  }
  if (
    typeof values.coquiMaxWorkers === "number" &&
    Number.isFinite(values.coquiMaxWorkers)
  ) {
    formData.append("coqui_max_workers", String(values.coquiMaxWorkers));
  }
  if (typeof values.coquiSafeMode === "boolean") {
    formData.append("coqui_safe_mode", values.coquiSafeMode ? "on" : "off");
  }
  if (
    typeof values.piperMaxProcs === "number" &&
    Number.isFinite(values.piperMaxProcs)
  ) {
    formData.append("piper_max_procs", String(values.piperMaxProcs));
  }
  if (values.bitrate) {
    formData.append("bitrate", values.bitrate);
  }
  if (
    typeof values.sampleRate === "number" &&
    Number.isFinite(values.sampleRate)
  ) {
    formData.append("sample_rate", String(values.sampleRate));
  }
  if (typeof values.channels === "number" && Number.isFinite(values.channels)) {
    formData.append("channels", String(values.channels));
  }
  if (typeof values.clearCache === "boolean") {
    formData.append("clear_cache", values.clearCache ? "on" : "off");
  }
  if (typeof values.forceReprocess === "boolean") {
    formData.append("force_reprocess", values.forceReprocess ? "on" : "off");
  }
  if (typeof values.filterChapters === "boolean") {
    formData.append("filter_chapters", values.filterChapters ? "on" : "off");
  }
  if (typeof values.verbose === "boolean") {
    formData.append("verbose", values.verbose ? "on" : "off");
  }
  if (typeof values.useLanguageDetection === "boolean") {
    formData.append(
      "use_language_detection",
      values.useLanguageDetection ? "on" : "off",
    );
  }
  if (typeof values.prioritizePrimaryLanguage === "boolean") {
    formData.append(
      "prioritize_primary_language",
      values.prioritizePrimaryLanguage ? "on" : "off",
    );
  }
  if (
    typeof values.healthCheckIntervalSeconds === "number" &&
    Number.isFinite(values.healthCheckIntervalSeconds)
  ) {
    formData.append(
      "health_check_interval_seconds",
      String(values.healthCheckIntervalSeconds),
    );
  }
  if (
    typeof values.healthCheckSlowEdgeCps === "number" &&
    Number.isFinite(values.healthCheckSlowEdgeCps)
  ) {
    formData.append(
      "health_check_slow_edge_cps",
      String(values.healthCheckSlowEdgeCps),
    );
  }
  if (
    typeof values.healthCheckSlowCps === "number" &&
    Number.isFinite(values.healthCheckSlowCps)
  ) {
    formData.append("health_check_slow_cps", String(values.healthCheckSlowCps));
  }
  if (
    typeof values.healthCheckHighCpu === "number" &&
    Number.isFinite(values.healthCheckHighCpu)
  ) {
    formData.append("health_check_high_cpu", String(values.healthCheckHighCpu));
  }
  if (
    typeof values.healthCheckHighMem === "number" &&
    Number.isFinite(values.healthCheckHighMem)
  ) {
    formData.append("health_check_high_mem", String(values.healthCheckHighMem));
  }
  if (
    typeof values.healthCheckOkCpu === "number" &&
    Number.isFinite(values.healthCheckOkCpu)
  ) {
    formData.append("health_check_ok_cpu", String(values.healthCheckOkCpu));
  }
  if (
    typeof values.healthCheckOkMem === "number" &&
    Number.isFinite(values.healthCheckOkMem)
  ) {
    formData.append("health_check_ok_mem", String(values.healthCheckOkMem));
  }
  if (
    typeof values.healthCheckSlowStreak === "number" &&
    Number.isFinite(values.healthCheckSlowStreak)
  ) {
    formData.append(
      "health_check_slow_streak",
      String(values.healthCheckSlowStreak),
    );
  }
  if (values.uiLanguage) {
    formData.append("ui_language", values.uiLanguage);
  }
  return formData;
}
// Exposed for tests
export const __buildFormData = buildFormData;

export function normalizeErrorMessage(
  status: number,
  statusText: string | undefined,
  body: string | undefined,
): string {
  if (status === 429) {
    return "The server is rate-limiting requests right now. On shared Hugging Face Spaces this usually means the instance is saturated. Please wait a bit and try again.";
  }
  const trimmedBody = body?.trim() ?? "";
  const statusLabel = statusText ? `${status} ${statusText}` : `${status}`;
  const fallback =
    status >= 500
      ? `Server responded with an internal error (${statusLabel}). Please try again shortly.`
      : `Request failed (${statusLabel}). Check and try again.`;

  if (!trimmedBody) {
    return fallback;
  }

  const tryParseJson = (): string | null => {
    if (!trimmedBody.startsWith("{") && !trimmedBody.startsWith("[")) {
      return null;
    }
    try {
      const payload = JSON.parse(trimmedBody);
      const detail = payload?.detail ?? payload?.error ?? payload?.message;
      if (typeof detail === "string" && detail.trim()) {
        return detail.trim();
      }
    } catch (_error) {
      return null;
    }
    return null;
  };

  const jsonMessage = tryParseJson();
  if (jsonMessage) {
    return jsonMessage;
  }

  if (/<!DOCTYPE\s+html/i.test(trimmedBody) || /<html/i.test(trimmedBody)) {
    return fallback;
  }

  if (trimmedBody.length > 500) {
    return `${trimmedBody.slice(0, 497)}...`;
  }

  return trimmedBody;
}

async function parseResponse<T>(response: Response): Promise<T> {
  if (!response.ok) {
    const text = await response.text();
    throw new Error(
      normalizeErrorMessage(response.status, response.statusText, text),
    );
  }
  return response.json() as Promise<T>;
}

export function normalizeAssetUrl(baseUrl: string, assetUrl: string): string {
  if (!assetUrl) {
    return assetUrl;
  }
  if (/^https?:\/\//i.test(assetUrl)) {
    return assetUrl;
  }

  const origin =
    typeof window !== "undefined" && window.location
      ? window.location.origin
      : "";
  const trimmedBase = (baseUrl || "").trim();

  if (trimmedBase && /^https?:\/\//i.test(trimmedBase)) {
    try {
      return new URL(assetUrl, trimmedBase).toString();
    } catch (_error) {
      return assetUrl;
    }
  }

  if (assetUrl.startsWith("/")) {
    return origin ? `${origin}${assetUrl}` : assetUrl;
  }

  if (trimmedBase) {
    const prefix = trimmedBase.startsWith("/")
      ? `${origin}${trimmedBase}`
      : origin
        ? `${origin}/${trimmedBase}`
        : trimmedBase;
    return `${prefix.replace(/\/$/, "")}/${assetUrl.replace(/^\//, "")}`;
  }

  return origin ? `${origin}/${assetUrl.replace(/^\//, "")}` : assetUrl;
}

async function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  if (signal?.aborted) {
    throw new DOMException("Aborted", "AbortError");
  }

  await new Promise<void>((resolve, reject) => {
    const timeout = setTimeout(() => {
      if (signal) {
        signal.removeEventListener("abort", onAbort);
      }
      resolve();
    }, ms);

    const onAbort = () => {
      clearTimeout(timeout);
      reject(new DOMException("Aborted", "AbortError"));
    };

    if (signal) {
      signal.addEventListener("abort", onAbort, { once: true });
    }
  });
}

export class HttpConversionClient implements ConversionClient {
  private resumableEndpointAvailable = true;

  constructor(private readonly baseUrl: string = API_BASE_URL) {}

  private supportsEventStream(): boolean {
    return (
      ENABLE_SSE &&
      typeof window !== "undefined" &&
      typeof window.EventSource === "function"
    );
  }

  private isTerminalState(state?: string | null): boolean {
    if (!state) {
      return false;
    }
    return ["finished", "failed", "interrupted", "cancelled"].includes(state);
  }

  private isTransientPollError(error: unknown): boolean {
    if (error instanceof DOMException && error.name === "AbortError") {
      return false;
    }
    if (!(error instanceof Error)) {
      return false;
    }
    const status = (error as Error & { status?: number }).status;
    if (typeof status === "number") {
      return status === 429 || status >= 500;
    }
    const message = error.message.toLowerCase();
    return (
      message.includes("failed to fetch") ||
      message.includes("network") ||
      message.includes("timeout")
    );
  }

  private resolve(path: string): string {
    const normalizedBase = this.baseUrl.replace(/\/$/, "");
    const normalizedPath = path.startsWith("/") ? path : `/${path}`;
    if (!normalizedBase) {
      return normalizeAssetUrl("", normalizedPath);
    }

    if (/^https?:\/\//i.test(normalizedBase)) {
      if (
        normalizedBase.endsWith("/api") &&
        normalizedPath.startsWith("/api")
      ) {
        return `${normalizedBase}${normalizedPath.substring(4)}`;
      }
      return `${normalizedBase}${normalizedPath}`;
    }

    if (normalizedBase.endsWith("/api") && normalizedPath.startsWith("/api")) {
      return `${normalizedBase}${normalizedPath.substring(4)}`;
    }

    return normalizeAssetUrl("", `${normalizedBase}${normalizedPath}`);
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
      normalized.coverUrl = normalizeAssetUrl(
        this.baseUrl,
        normalized.coverUrl,
      );
    }

    if (Array.isArray(normalized.chapterProgress)) {
      normalized.chapterProgress = normalized.chapterProgress.map(
        (chapter) => ({
          ...chapter,
          downloadUrl: chapter.downloadUrl
            ? normalizeAssetUrl(this.baseUrl, chapter.downloadUrl)
            : undefined,
        }),
      );
    }

    return normalized;
  }

  async submit(request: ConversionFormValues): Promise<{ jobId: string }> {
    const response = await fetch(this.resolve("/api/convert"), {
      method: "POST",
      body: buildFormData(request),
    });

    // Auto-recover: if the upload expired on the server but we still have the
    // original local file path (desktop app), re-register it and retry once.
    if (
      !response.ok &&
      response.status === 404 &&
      request.localPath &&
      request.uploadId
    ) {
      const body = await response.text();
      if (body.includes("Upload not found") || body.includes("expired")) {
        try {
          const reReg = await fetch(this.resolve("/api/uploads/local"), {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ path: request.localPath }),
          });
          if (reReg.ok) {
            const newUpload: UploadResponse = await reReg.json();
            const retryResp = await fetch(this.resolve("/api/convert"), {
              method: "POST",
              body: buildFormData({ ...request, uploadId: newUpload.uploadId }),
            });
            return parseResponse<{ jobId: string }>(retryResp);
          }
        } catch {
          // Re-registration failed; fall through to original error below
        }
        throw new Error(
          normalizeErrorMessage(response.status, response.statusText, body),
        );
      }
    }

    return parseResponse<{ jobId: string }>(response);
  }

  async fetch(jobId: string, signal?: AbortSignal): Promise<JobSnapshot> {
    const response = await fetch(
      this.resolve(`/api/jobs/${encodeURIComponent(jobId)}`),
      {
        method: "GET",
        signal,
      },
    );
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
    if (this.supportsEventStream()) {
      const streamed = await this.pollWithEventSource(jobId, options);
      if (streamed) {
        return streamed;
      }
    }
    return this.pollWithHttp(jobId, options);
  }

  async cancel(jobId: string): Promise<{ status: string }> {
    const response = await fetch(
      this.resolve(`/api/jobs/${encodeURIComponent(jobId)}/cancel`),
      {
        method: "POST",
      },
    );
    return parseResponse<{ status: string }>(response);
  }

  async resume(jobId: string): Promise<{ status: string }> {
    const response = await fetch(
      this.resolve(`/api/jobs/${encodeURIComponent(jobId)}/resume`),
      {
        method: "POST",
      },
    );
    return parseResponse<{ status: string }>(response);
  }

  async removeJob(jobId: string): Promise<{ status: string }> {
    const response = await fetch(
      this.resolve(`/api/jobs/${encodeURIComponent(jobId)}`),
      {
        method: "DELETE",
      },
    );
    return parseResponse<{ status: string }>(response);
  }

  async restartBackend(options?: RestartOptions): Promise<{ status: string }> {
    const response = await fetch(this.resolve("/api/system/restart"), {
      method: "POST",
      headers: options ? { "Content-Type": "application/json" } : undefined,
      body: options ? JSON.stringify(options) : undefined,
    });
    return parseResponse<{ status: string }>(response);
  }

  async upload(file: File): Promise<UploadResponse> {
    const formData = new FormData();
    formData.append("file", file);
    const response = await fetch(this.resolve("/api/uploads"), {
      method: "POST",
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
      const response = await fetch(this.resolve("/api/jobs/resumable"), {
        method: "GET",
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
      if (error instanceof Error && error.message.includes("404")) {
        this.resumableEndpointAvailable = false;
        return null;
      }
      console.warn("[ConversionClient] Failed to fetch resumable jobs:", error);
      return null;
    }
  }

  async getRecentJobs(): Promise<RecentJobEntry[] | null> {
    const response = await fetch(this.resolve("/api/jobs/recent"), {
      method: "GET",
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
      const response = await fetch(url, { method: "GET" });
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
            typeof chunk.index === "number" && Number.isFinite(chunk.index)
              ? chunk.index
              : idx,
        }))
        .sort((a, b) => a.index - b.index);
      return { ...payload, chunks: normalizedChunks };
    } catch (error) {
      console.warn(
        "[ConversionClient] Failed to fetch stream manifest:",
        error,
      );
      return null;
    }
  }

  async getJobFullText(jobId: string): Promise<BookTextDocument | null> {
    const url = this.resolve(`/api/jobs/${encodeURIComponent(jobId)}/fulltext`);
    try {
      const response = await fetch(url, { method: "GET" });
      if (!response.ok) {
        return null;
      }
      const payload = (await response.json()) as BookTextDocument;
      if (!payload || !Array.isArray(payload.chapters)) {
        return null;
      }
      return {
        ...payload,
        chapters: payload.chapters.map((chapter, index) => ({
          index:
            typeof chapter.index === "number" && Number.isFinite(chapter.index)
              ? chapter.index
              : index,
          name: chapter.name || `Chapter ${index}`,
          text: chapter.text || "",
          html: typeof chapter.html === "string" ? chapter.html : undefined,
          css: typeof chapter.css === "string" ? chapter.css : undefined,
          charCount:
            typeof chapter.charCount === "number" &&
            Number.isFinite(chapter.charCount)
              ? chapter.charCount
              : (chapter.text || "").length,
        })),
      };
    } catch (error) {
      console.warn("[ConversionClient] Failed to fetch full text:", error);
      return null;
    }
  }

  private async pollWithHttp(
    jobId: string,
    options: PollOptions,
  ): Promise<JobSnapshot> {
    const interval = options.intervalMs ?? POLL_INTERVAL_MS;
    const { signal } = options;
    let retryDelay = interval;

    while (!signal?.aborted) {
      try {
        const snapshot = await this.fetch(jobId, signal);
        options.onSnapshot?.(snapshot);
        retryDelay = interval;

        if (this.isTerminalState(snapshot.state)) {
          return snapshot;
        }

        await sleep(interval, signal);
      } catch (error) {
        if (signal?.aborted) {
          throw error;
        }
        if (this.isTransientPollError(error)) {
          await sleep(retryDelay, signal);
          retryDelay = Math.min(Math.round(retryDelay * 1.6), 15000);
          continue;
        }
        throw error;
      }
    }

    throw new DOMException("Aborted", "AbortError");
  }

  private async pollWithEventSource(
    jobId: string,
    options: PollOptions,
  ): Promise<JobSnapshot | null> {
    if (!this.supportsEventStream()) {
      return null;
    }
    const { signal } = options;
    if (signal?.aborted) {
      throw new DOMException("Aborted", "AbortError");
    }

    const streamUrl = this.resolve(
      `/api/jobs/${encodeURIComponent(jobId)}/stream`,
    );

    return new Promise<JobSnapshot | null>((resolve, reject) => {
      let settled = false;
      let source: EventSource | null = null;

      const cleanup = () => {
        if (source) {
          source.onmessage = null;
          source.onerror = null;
          source.close();
          source = null;
        }
        if (signal) {
          signal.removeEventListener("abort", handleAbort);
        }
      };

      const finalize = (payload: JobSnapshot | null) => {
        if (settled) return;
        settled = true;
        cleanup();
        resolve(payload);
      };

      const handleAbort = () => {
        cleanup();
        reject(new DOMException("Aborted", "AbortError"));
      };

      // Track the latest full snapshot so chapter_update events can patch it
      let latestSnapshot: JobSnapshot | null = null;

      const handleMessage = (event: MessageEvent) => {
        try {
          const payload = JSON.parse(event.data) as JobSnapshot;
          const snapshot = this.normalizeSnapshot(payload);
          latestSnapshot = snapshot;
          options.onSnapshot?.(snapshot);
          if (this.isTerminalState(snapshot.state)) {
            finalize(snapshot);
          }
        } catch (error) {
          console.warn(
            "[ConversionClient] Failed to parse SSE payload:",
            error,
          );
        }
      };

      const handleChapterUpdate = (event: MessageEvent) => {
        try {
          if (!latestSnapshot || !Array.isArray(latestSnapshot.chapterProgress))
            return;
          const chapter = JSON.parse(event.data) as Record<string, unknown>;
          const chapterIndex = chapter["index"];
          const idx = latestSnapshot.chapterProgress.findIndex(
            (c) => c.index === chapterIndex,
          );
          if (idx === -1) return;
          const updated = [...latestSnapshot.chapterProgress];
          updated[idx] = { ...updated[idx], ...chapter };
          latestSnapshot = { ...latestSnapshot, chapterProgress: updated };
          options.onSnapshot?.(latestSnapshot);
        } catch {
          // Ignore malformed chapter_update events
        }
      };

      const handleError = () => {
        finalize(null);
      };

      try {
        source = new EventSource(streamUrl, { withCredentials: true });
      } catch (error) {
        console.warn(
          "[ConversionClient] Failed to establish SSE connection:",
          error,
        );
        finalize(null);
        return;
      }

      source.onmessage = handleMessage;
      source.addEventListener("chapter_update", handleChapterUpdate);
      source.onerror = handleError;

      if (signal) {
        signal.addEventListener("abort", handleAbort, { once: true });
      }
    });
  }
}

export class MockConversionClient implements ConversionClient {
  private jobCounter = 0;

  private createMockAudio(
    chapterName: string,
    durationSeconds: number,
  ): string {
    // Create a simple audio context to generate a beep tone
    const webkitAudioContext = (
      window as Window & { webkitAudioContext?: typeof AudioContext }
    ).webkitAudioContext;
    const AudioContextCtor = window.AudioContext ?? webkitAudioContext;
    if (!AudioContextCtor) {
      throw new Error("AudioContext is not supported in this environment.");
    }
    const audioContext = new AudioContextCtor();
    const sampleRate = audioContext.sampleRate;
    const duration = durationSeconds;
    const numSamples = sampleRate * duration;
    const audioBuffer = audioContext.createBuffer(1, numSamples, sampleRate);
    const channelData = audioBuffer.getChannelData(0);

    // Generate a simple sine wave beep at 440Hz (A note)
    const frequency = 440;
    for (let i = 0; i < numSamples; i++) {
      const t = i / sampleRate;
      // Fade in/out envelope to avoid clicks
      const envelope = Math.min(t * 10, (duration - t) * 10, 1);
      channelData[i] = Math.sin(2 * Math.PI * frequency * t) * 0.3 * envelope;
    }

    // Convert to WAV format
    const wav = this.audioBufferToWav(audioBuffer);
    const blob = new Blob([wav], { type: "audio/wav" });
    return URL.createObjectURL(blob);
  }

  private audioBufferToWav(buffer: AudioBuffer): ArrayBuffer {
    const numChannels = buffer.numberOfChannels;
    const sampleRate = buffer.sampleRate;
    const format = 1; // PCM
    const bitDepth = 16;

    const bytesPerSample = bitDepth / 8;
    const blockAlign = numChannels * bytesPerSample;

    const data = this.interleave(buffer);
    const dataLength = data.length * bytesPerSample;
    const headerLength = 44;
    const totalLength = headerLength + dataLength;

    const arrayBuffer = new ArrayBuffer(totalLength);
    const view = new DataView(arrayBuffer);

    // Write WAV header
    this.writeString(view, 0, "RIFF");
    view.setUint32(4, totalLength - 8, true);
    this.writeString(view, 8, "WAVE");
    this.writeString(view, 12, "fmt ");
    view.setUint32(16, 16, true); // fmt chunk size
    view.setUint16(20, format, true);
    view.setUint16(22, numChannels, true);
    view.setUint32(24, sampleRate, true);
    view.setUint32(28, sampleRate * blockAlign, true);
    view.setUint16(32, blockAlign, true);
    view.setUint16(34, bitDepth, true);
    this.writeString(view, 36, "data");
    view.setUint32(40, dataLength, true);

    // Write audio data
    this.floatTo16BitPCM(view, 44, data);

    return arrayBuffer;
  }

  private interleave(buffer: AudioBuffer): Float32Array {
    const numChannels = buffer.numberOfChannels;
    const length = buffer.length * numChannels;
    const result = new Float32Array(length);

    for (let channel = 0; channel < numChannels; channel++) {
      const channelData = buffer.getChannelData(channel);
      for (let i = 0; i < buffer.length; i++) {
        result[i * numChannels + channel] = channelData[i];
      }
    }

    return result;
  }

  private writeString(view: DataView, offset: number, str: string): void {
    for (let i = 0; i < str.length; i++) {
      view.setUint8(offset + i, str.charCodeAt(i));
    }
  }

  private floatTo16BitPCM(
    view: DataView,
    offset: number,
    input: Float32Array,
  ): void {
    for (let i = 0; i < input.length; i++, offset += 2) {
      const s = Math.max(-1, Math.min(1, input[i]));
      view.setInt16(offset, s < 0 ? s * 0x8000 : s * 0x7fff, true);
    }
  }

  async submit(request: ConversionFormValues): Promise<{ jobId: string }> {
    this.jobCounter++;
    const jobId = `mock-job-${this.jobCounter}`;
    console.log("[MockClient] Conversion started:", { jobId, request });
    return { jobId };
  }

  async cancel(_jobId: string): Promise<{ status: string }> {
    return { status: "cancelled" };
  }

  async resume(_jobId: string): Promise<{ status: string }> {
    return { status: "queued" };
  }

  async removeJob(_jobId: string): Promise<{ status: string }> {
    return { status: "deleted" };
  }

  async restartBackend(_options?: RestartOptions): Promise<{ status: string }> {
    return { status: "restarting" };
  }

  async fetch(jobId: string): Promise<JobSnapshot> {
    return {
      jobId,
      state: "queued",
      events: ["Mock: Job received", "Mock: Processing started"],
    };
  }

  async getResumableJobs(): Promise<ResumableJob[] | null> {
    return [];
  }

  async getChapterManifest(
    _jobId: string,
    _chapterIndex: number,
  ): Promise<ChapterStreamManifest | null> {
    return null;
  }

  async getJobFullText(_jobId: string): Promise<BookTextDocument | null> {
    return null;
  }

  private createMockZip(bookTitle: string): string {
    // Create a simple ZIP-like file with mock content
    const content = `Mock Audiobook ZIP: ${bookTitle}

This ZIP file would contain:
- 001 - Chapter 1.mp3
- 002 - Chapter 2.mp3
- 003 - Chapter 3.mp3

Generated: ${new Date().toISOString()}
Note: In production, this would be a real ZIP with all MP3 files.
`;
    const blob = new Blob([content], { type: "application/zip" });
    return URL.createObjectURL(blob);
  }

  async poll(jobId: string, options: PollOptions = {}): Promise<JobSnapshot> {
    const bookTitle = "Livro_de_Exemplo";
    const coverUrl =
      "https://images.unsplash.com/photo-1524995997946-a1c2e315a42f?w=720&auto=format&fit=crop";

    // Create individual chapter MP3s with different durations
    const chapter1 = this.createMockAudio("001 - Chapter 1", 3);
    const chapter2 = this.createMockAudio("002 - Chapter 2", 4);
    const chapter3 = this.createMockAudio("003 - Chapter 3", 5);
    const zipUrl = this.createMockZip(bookTitle);

    const parallelSlots = 3;
    const steps: JobSnapshot[] = [
      {
        jobId,
        state: "running",
        events: [
          "📚 EBOOK METADATA",
          "================================================================",
          "📜 Title: Sample Book",
          "✍️ Author: Unknown Author",
          "📊 Chapters: 3",
          "📝 Total characters: 12,450",
        ],
        chaptersTotal: 3,
        chaptersCompleted: 0,
        progressPercent: 5,
        bookTitle: "Sample Book",
        bookAuthor: "Unknown Author",
        coverUrl,
        parallelSlots,
        parallelActive: 0,
      },
      {
        jobId,
        state: "running",
        events: [
          "📚 EBOOK METADATA",
          "================================================================",
          "📜 Title: Sample Book",
          "✍️ Author: Unknown Author",
          "📊 Chapters: 3",
          "📝 Total characters: 12,450",
          "",
          "🌐 LANGUAGE DETECTION",
          "----------------------------------------------------------------",
          "🌐 Primary language: pt-BR (confidence: High)",
          "   Probability: 95.2%",
          "🔍 Analyzed characters: 12,450",
        ],
        detectedLanguage: "pt-BR",
        chaptersTotal: 3,
        chaptersCompleted: 0,
        progressPercent: 15,
        bookTitle: "Sample Book",
        bookAuthor: "Unknown Author",
        coverUrl,
        parallelSlots,
        parallelActive: 0,
      },
      {
        jobId,
        state: "running",
        events: [
          "📚 EBOOK METADATA",
          "================================================================",
          "📜 Title: Sample Book",
          "✍️ Author: Unknown Author",
          "📊 Chapters: 3",
          "📝 Total characters: 12,450",
          "",
          "🌐 LANGUAGE DETECTION",
          "----------------------------------------------------------------",
          "🌐 Primary language: pt-BR (confidence: High)",
          "   Probability: 95.2%",
          "🔍 Analyzed characters: 12,450",
          "",
          "🔄 Automatic sequential mode: processing one chapter at a time",
          "🎯 Converting chapter 1/3: Chapter 1",
          "Processing: [██████████░░░░░░░░░░░░░░░░░░░░] 33.3% (1/3) ETA: 0m 45s",
        ],
        detectedLanguage: "pt-BR",
        chaptersTotal: 3,
        chaptersCompleted: 1,
        currentChapter: "Chapter 1",
        progressPercent: 33,
        bookTitle: "Sample Book",
        bookAuthor: "Unknown Author",
        coverUrl,
        parallelSlots,
        parallelActive: 1,
      },
      {
        jobId,
        state: "running",
        events: [
          "📚 EBOOK METADATA",
          "================================================================",
          "📜 Title: Sample Book",
          "✍️ Author: Unknown Author",
          "📊 Chapters: 3",
          "📝 Total characters: 12,450",
          "",
          "🌐 LANGUAGE DETECTION",
          "----------------------------------------------------------------",
          "🌐 Primary language: pt-BR (confidence: High)",
          "   Probability: 95.2%",
          "🔍 Analyzed characters: 12,450",
          "",
          "🚀 Automatic parallel: up to 3 simultaneous chapters",
          "🎯 Converting chapter 1/3: Chapter 1",
          "Processing: [██████████░░░░░░░░░░░░░░░░░░░░] 33.3% (1/3) ETA: 0m 45s",
          "✅ Completed: 001 - Chapter 1.mp3",
          "",
          "🎯 Converting chapter 2/3: Chapter 2",
          "🎯 Converting chapter 3/3: Chapter 3",
          "Processing: [████████████████████░░░░░░░░░░] 66.7% (2/3) ETA: 0m 22s",
        ],
        detectedLanguage: "pt-BR",
        chaptersTotal: 3,
        chaptersCompleted: 2,
        currentChapter: "Chapter 2",
        progressPercent: 67,
        bookTitle: "Sample Book",
        bookAuthor: "Unknown Author",
        coverUrl,
        parallelSlots,
        parallelActive: 2,
      },
      {
        jobId,
        state: "finished",
        events: [
          "📚 EBOOK METADATA",
          "================================================================",
          "📜 Title: Sample Book",
          "✍️ Author: Unknown Author",
          "📊 Chapters: 3",
          "📝 Total characters: 12,450",
          "",
          "🌐 LANGUAGE DETECTION",
          "----------------------------------------------------------------",
          "🌐 Primary language: pt-BR (confidence: High)",
          "   Probability: 95.2%",
          "🔍 Analyzed characters: 12,450",
          "",
          "🚀 Automatic parallel: up to 3 simultaneous chapters",
          "🎯 Converting chapter 1/3: Chapter 1",
          "Processing: [██████████░░░░░░░░░░░░░░░░░░░░] 33.3% (1/3) ETA: 0m 45s",
          "✅ Completed: 001 - Chapter 1.mp3",
          "",
          "🎯 Converting chapter 2/3: Chapter 2",
          "Processing: [████████████████████░░░░░░░░░░] 66.7% (2/3) ETA: 0m 22s",
          "✅ Completed: 002 - Chapter 2.mp3",
          "",
          "🎯 Converting chapter 3/3: Chapter 3",
          "Processing: [██████████████████████████████] 100.0% (3/3) ETA: 0m 0s",
          "✅ Completed: 003 - Chapter 3.mp3",
          "",
          "📦 Creating ZIP file: Livro_de_Exemplo.zip",
          "✅ Conversion finished in 1m 8s",
          "📁 Available file: Livro_de_Exemplo.zip (3 chapters)",
        ],
        detectedLanguage: "pt-BR",
        chaptersTotal: 3,
        chaptersCompleted: 3,
        currentChapter: "Chapter 3",
        progressPercent: 100,
        outputs: [
          { name: "Livro_de_Exemplo.zip", url: zipUrl },
          { name: "001 - Chapter 1.mp3", url: chapter1, durationSeconds: 180 },
          { name: "002 - Chapter 2.mp3", url: chapter2, durationSeconds: 240 },
          { name: "003 - Chapter 3.mp3", url: chapter3, durationSeconds: 300 },
        ],
        bookTitle: "Sample Book",
        bookAuthor: "Unknown Author",
        coverUrl,
        parallelSlots,
        parallelActive: 0,
      },
    ];

    for (const step of steps) {
      await sleep(1800);
      options.onSnapshot?.(step);
      if (step.state === "finished") {
        return step;
      }
    }

    return steps[steps.length - 1];
  }
}

export const conversionClient = new HttpConversionClient();
export const mockConversionClient = new MockConversionClient();
