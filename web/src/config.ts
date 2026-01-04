const FALLBACK_API_BASE = "/api";
const DEFAULT_MAX_UPLOAD_MB = Number(import.meta.env.VITE_MAX_UPLOAD_MB || 100);

export const API_BASE_URL: string =
  (import.meta.env.VITE_API_BASE as string | undefined) || FALLBACK_API_BASE;
export const POLL_INTERVAL_MS: number = Number(
  import.meta.env.VITE_POLL_INTERVAL_MS || 3000,
);
// Default to SSE enabled; allow explicit disable via env (false/0/no)
const ENABLE_SSE_RAW = String(
  import.meta.env.VITE_ENABLE_SSE ?? "true",
).toLowerCase();
export const ENABLE_SSE =
  ENABLE_SSE_RAW === "true" ||
  ENABLE_SSE_RAW === "1" ||
  ENABLE_SSE_RAW === "yes";
export const MAX_UPLOAD_MB = DEFAULT_MAX_UPLOAD_MB;
export const MAX_UPLOAD_BYTES = MAX_UPLOAD_MB * 1024 * 1024;

export function resolveApiUrl(path: string): string {
  const normalizedBase = (API_BASE_URL || "").replace(/\/$/, "");
  const normalizedPath = path.startsWith("/") ? path : `/${path}`;
  if (!normalizedBase) {
    return normalizedPath;
  }

  if (/^https?:\/\//i.test(normalizedBase)) {
    if (normalizedBase.endsWith("/api") && normalizedPath.startsWith("/api")) {
      return `${normalizedBase}${normalizedPath.substring(4)}`;
    }
    return `${normalizedBase}${normalizedPath}`;
  }

  if (normalizedBase.endsWith("/api") && normalizedPath.startsWith("/api")) {
    return `${normalizedBase}${normalizedPath.substring(4)}`;
  }

  return `${normalizedBase}${normalizedPath}`;
}
