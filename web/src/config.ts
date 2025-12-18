const FALLBACK_API_BASE = '/api';
const DEFAULT_MAX_UPLOAD_MB = Number(import.meta.env.VITE_MAX_UPLOAD_MB || 100);

export const API_BASE_URL: string = (import.meta.env.VITE_API_BASE as string | undefined) || FALLBACK_API_BASE;
export const POLL_INTERVAL_MS: number = Number(import.meta.env.VITE_POLL_INTERVAL_MS || 3000);
export const MAX_UPLOAD_MB = DEFAULT_MAX_UPLOAD_MB;
export const MAX_UPLOAD_BYTES = MAX_UPLOAD_MB * 1024 * 1024;
