import { ENABLE_SSE, POLL_INTERVAL_MS } from '../config';
import type { JobSnapshot } from '../types/conversion';
import type { PollOptions } from './conversion_client_contract';
import { sleep } from './http_conversion_response';

interface HttpPollContext {
  fetch(jobId: string, signal?: AbortSignal): Promise<JobSnapshot>;
  resolve(path: string): string;
  normalizeSnapshot(snapshot: JobSnapshot): JobSnapshot;
}

export function supportsEventStream(): boolean {
  return ENABLE_SSE && typeof window !== 'undefined' && typeof window.EventSource === 'function';
}

export function isTerminalState(state?: string | null): boolean {
  if (!state) {
    return false;
  }
  return ['finished', 'failed', 'interrupted', 'cancelled'].includes(state);
}

export function isTransientPollError(error: unknown): boolean {
  if (error instanceof DOMException && error.name === 'AbortError') {
    return false;
  }
  if (!(error instanceof Error)) {
    return false;
  }
  const status = (error as Error & { status?: number }).status;
  if (typeof status === 'number') {
    return status === 429 || status >= 500;
  }
  const message = error.message.toLowerCase();
  return (
    message.includes('failed to fetch') ||
    message.includes('network') ||
    message.includes('timeout')
  );
}

export async function pollWithHttp(
  client: HttpPollContext,
  jobId: string,
  options: PollOptions,
): Promise<JobSnapshot> {
  const interval = options.intervalMs ?? POLL_INTERVAL_MS;
  const { signal } = options;
  let retryDelay = interval;

  while (!signal?.aborted) {
    try {
      const snapshot = await client.fetch(jobId, signal);
      options.onSnapshot?.(snapshot);
      retryDelay = interval;

      if (isTerminalState(snapshot.state)) {
        return snapshot;
      }

      await sleep(interval, signal);
    } catch (error) {
      if (signal?.aborted) {
        throw error;
      }
      if (isTransientPollError(error)) {
        await sleep(retryDelay, signal);
        retryDelay = Math.min(Math.round(retryDelay * 1.6), 15000);
        continue;
      }
      throw error;
    }
  }

  throw new DOMException('Aborted', 'AbortError');
}

export async function pollWithEventSource(
  client: HttpPollContext,
  jobId: string,
  options: PollOptions,
): Promise<JobSnapshot | null> {
  if (!supportsEventStream()) {
    return null;
  }
  const { signal } = options;
  if (signal?.aborted) {
    throw new DOMException('Aborted', 'AbortError');
  }
  options.onStreamStatus?.('connecting');

  const streamUrl = client.resolve(`/api/jobs/${encodeURIComponent(jobId)}/stream`);

  return new Promise<JobSnapshot | null>((resolve, reject) => {
    let settled = false;
    let source: EventSource | null = null;
    let retryTimer: number | null = null;
    let idleTimer: number | null = null;
    let retryCount = 0;
    const retryDelaysMs = [2000, 4000, 8000] as const;
    // Tauri WKWebView on macOS keeps the SSE TCP connection open during
    // long backend silences (e.g. Edge slow mode) but never fires onmessage
    // or onerror — the UI freezes. The backend heartbeat is a ":" comment
    // and is invisible to EventSource. We add a client-side idle watchdog:
    // if no message arrives within this window, force a reconnect.
    const IDLE_WATCHDOG_MS = 25000;

    const clearIdleTimer = () => {
      if (idleTimer !== null) {
        window.clearTimeout(idleTimer);
        idleTimer = null;
      }
    };

    const armIdleTimer = () => {
      clearIdleTimer();
      idleTimer = window.setTimeout(() => {
        idleTimer = null;
        scheduleReconnect();
      }, IDLE_WATCHDOG_MS);
    };

    const cleanup = () => {
      clearIdleTimer();
      if (source) {
        source.onmessage = null;
        source.onerror = null;
        source.close();
        source = null;
      }
      if (retryTimer !== null) {
        window.clearTimeout(retryTimer);
        retryTimer = null;
      }
      if (signal) {
        signal.removeEventListener('abort', handleAbort);
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
      reject(new DOMException('Aborted', 'AbortError'));
    };

    // Track the latest full snapshot so chapter_update events can patch it
    let latestSnapshot: JobSnapshot | null = null;

    const handleMessage = (event: MessageEvent) => {
      try {
        retryCount = 0;
        armIdleTimer();
        const payload = JSON.parse(event.data) as JobSnapshot;
        const snapshot = client.normalizeSnapshot(payload);
        latestSnapshot = snapshot;
        options.onStreamStatus?.('healthy');
        options.onSnapshot?.(snapshot);
        if (isTerminalState(snapshot.state)) {
          finalize(snapshot);
        }
      } catch (error) {
        console.warn('[ConversionClient] Failed to parse SSE payload:', error);
      }
    };

    const handleChapterUpdate = (event: MessageEvent) => {
      try {
        retryCount = 0;
        armIdleTimer();
        if (!latestSnapshot || !Array.isArray(latestSnapshot.chapterProgress)) return;
        const chapter = JSON.parse(event.data) as Record<string, unknown>;
        const chapterIndex = chapter['index'];
        const idx = latestSnapshot.chapterProgress.findIndex((c) => c.index === chapterIndex);
        if (idx === -1) return;
        const updated = [...latestSnapshot.chapterProgress];
        updated[idx] = { ...updated[idx], ...chapter };
        latestSnapshot = { ...latestSnapshot, chapterProgress: updated };
        options.onSnapshot?.(latestSnapshot);
      } catch {
        // Ignore malformed chapter_update events
      }
    };

    const closeSource = () => {
      clearIdleTimer();
      if (!source) {
        return;
      }
      source.onmessage = null;
      source.onerror = null;
      source.removeEventListener('chapter_update', handleChapterUpdate);
      source.close();
      source = null;
    };

    const scheduleReconnect = () => {
      closeSource();
      if (retryCount >= retryDelaysMs.length) {
        finalize(null);
        return;
      }
      const delayMs = retryDelaysMs[retryCount];
      retryCount += 1;
      retryTimer = window.setTimeout(() => {
        retryTimer = null;
        connect();
      }, delayMs);
    };

    const handleError = () => {
      scheduleReconnect();
    };

    const connect = () => {
      try {
        source = new EventSource(streamUrl, { withCredentials: true });
      } catch (error) {
        console.warn('[ConversionClient] Failed to establish SSE connection:', error);
        closeSource();
        scheduleReconnect();
        return;
      }

      source.onmessage = handleMessage;
      source.addEventListener('chapter_update', handleChapterUpdate);
      source.onerror = handleError;
      armIdleTimer();
    };

    if (signal) {
      signal.addEventListener('abort', handleAbort, { once: true });
    }

    connect();
  });
}
