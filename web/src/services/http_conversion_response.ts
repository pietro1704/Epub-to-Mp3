export function normalizeErrorMessage(
  status: number,
  statusText: string | undefined,
  body: string | undefined,
): string {
  if (status === 429) {
    return 'The server is rate-limiting requests right now. On shared Hugging Face Spaces this usually means the instance is saturated. Please wait a bit and try again.';
  }
  const trimmedBody = body?.trim() ?? '';
  const statusLabel = statusText ? `${status} ${statusText}` : `${status}`;
  const fallback =
    status >= 500
      ? `Server responded with an internal error (${statusLabel}). Please try again shortly.`
      : `Request failed (${statusLabel}). Check and try again.`;

  if (!trimmedBody) {
    return fallback;
  }

  const tryParseJson = (): string | null => {
    if (!trimmedBody.startsWith('{') && !trimmedBody.startsWith('[')) {
      return null;
    }
    try {
      const payload = JSON.parse(trimmedBody);
      const detail = payload?.detail ?? payload?.error ?? payload?.message;
      if (typeof detail === 'string' && detail.trim()) {
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

export async function parseResponse<T>(response: Response): Promise<T> {
  if (!response.ok) {
    const text = await response.text();
    throw new Error(normalizeErrorMessage(response.status, response.statusText, text));
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

  const origin = typeof window !== 'undefined' && window.location ? window.location.origin : '';
  const trimmedBase = (baseUrl || '').trim();

  if (trimmedBase && /^https?:\/\//i.test(trimmedBase)) {
    try {
      return new URL(assetUrl, trimmedBase).toString();
    } catch (_error) {
      return assetUrl;
    }
  }

  if (assetUrl.startsWith('/')) {
    return origin ? `${origin}${assetUrl}` : assetUrl;
  }

  if (trimmedBase) {
    const prefix = trimmedBase.startsWith('/')
      ? `${origin}${trimmedBase}`
      : origin
        ? `${origin}/${trimmedBase}`
        : trimmedBase;
    return `${prefix.replace(/\/$/, '')}/${assetUrl.replace(/^\//, '')}`;
  }

  return origin ? `${origin}/${assetUrl.replace(/^\//, '')}` : assetUrl;
}

export async function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  if (signal?.aborted) {
    throw new DOMException('Aborted', 'AbortError');
  }

  await new Promise<void>((resolve, reject) => {
    const timeout = setTimeout(() => {
      if (signal) {
        signal.removeEventListener('abort', onAbort);
      }
      resolve();
    }, ms);

    const onAbort = () => {
      clearTimeout(timeout);
      reject(new DOMException('Aborted', 'AbortError'));
    };

    if (signal) {
      signal.addEventListener('abort', onAbort, { once: true });
    }
  });
}
