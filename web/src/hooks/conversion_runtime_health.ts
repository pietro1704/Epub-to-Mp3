import { ConversionClient } from '../services/ConversionService';
import { JobSnapshot } from '../types/conversion';
import { resolveApiUrl } from '../config';
import { DEFAULT_TOLERANCES } from './conversion_eta';

export const resolveHealthEndpoint = (): string => resolveApiUrl('/api/health');

export const RESTART_GRACE_MS = 15000;

export const INITIAL_FETCH_RETRY_ATTEMPTS = 5;

export const INITIAL_FETCH_RETRY_BASE_DELAY_MS = 500;

export const INITIAL_FETCH_RETRY_MAX_DELAY_MS = 4000;

export const sleepMs = (ms: number): Promise<void> =>
  new Promise((resolve) => {
    setTimeout(resolve, ms);
  });

export const pingBackendHealth = async (
  timeoutMs: number = DEFAULT_TOLERANCES.healthPingTimeoutMs,
): Promise<boolean> => {
  const endpoint = resolveHealthEndpoint();
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), timeoutMs);
    const response = await fetch(endpoint, {
      method: 'GET',
      cache: 'no-store',
      signal: controller.signal,
    });
    clearTimeout(timeout);
    return response.ok;
  } catch {
    return false;
  }
};

export const isNetworkError = (error: unknown): boolean => {
  if (!(error instanceof Error)) {
    return false;
  }
  const status = (error as Error & { status?: number }).status;
  if (typeof status === 'number') {
    return status === 404 || status === 429 || status >= 500;
  }
  const message = error.message.toLowerCase();
  return (
    message.includes('404') ||
    message.includes('not found') ||
    message.includes('429') ||
    message.includes('rate limit') ||
    message.includes('too many requests') ||
    message.includes('failed to fetch') ||
    message.includes('network') ||
    message.includes('timeout')
  );
};

export async function fetchInitialJobSnapshot(
  api: ConversionClient,
  jobId: string,
  isCurrent: () => boolean = () => true,
): Promise<JobSnapshot | null> {
  if (!api.fetch) {
    return null;
  }
  let attempt = 0;
  while (attempt < INITIAL_FETCH_RETRY_ATTEMPTS) {
    if (!isCurrent()) throw new DOMException('Aborted', 'AbortError');
    try {
      return await api.fetch(jobId);
    } catch (error) {
      const isNotFoundError = error instanceof Error && error.message.includes('404');
      if (!isNotFoundError) {
        throw error;
      }
      attempt += 1;
      if (attempt >= INITIAL_FETCH_RETRY_ATTEMPTS) {
        return null;
      }
      const backoff = Math.min(
        INITIAL_FETCH_RETRY_BASE_DELAY_MS * Math.pow(1.5, Math.max(0, attempt - 1)),
        INITIAL_FETCH_RETRY_MAX_DELAY_MS,
      );
      await sleepMs(backoff);
    }
  }
  return null;
}

export async function fetchResumedJobSnapshot(
  api: ConversionClient,
  actualJobId: string,
  isCurrent: () => boolean,
): Promise<JobSnapshot> {
  let attempt = 0;
  while (attempt < INITIAL_FETCH_RETRY_ATTEMPTS) {
    if (!isCurrent()) throw new DOMException('Aborted', 'AbortError');
    try {
      return await api.fetch(actualJobId);
    } catch (error) {
      const isNotFoundError = error instanceof Error && error.message.includes('404');
      if (!isNotFoundError) {
        throw error;
      }
      attempt += 1;
      if (attempt >= INITIAL_FETCH_RETRY_ATTEMPTS) {
        throw error;
      }
      const backoff = Math.min(
        INITIAL_FETCH_RETRY_BASE_DELAY_MS * Math.pow(1.5, Math.max(0, attempt - 1)),
        INITIAL_FETCH_RETRY_MAX_DELAY_MS,
      );
      console.info(
        `[useConversionFlow] Job ${actualJobId} not yet persisted in backend (attempt ${attempt}/${INITIAL_FETCH_RETRY_ATTEMPTS}). Waiting ${backoff}ms before retrying.`,
      );
      await sleepMs(backoff);
    }
  }
  throw new Error('Failed to load initial conversion state');
}
