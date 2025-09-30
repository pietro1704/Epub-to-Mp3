const FALLBACK_API_BASE = '/api';

export const API_BASE_URL: string = (import.meta.env.VITE_API_BASE as string | undefined) || FALLBACK_API_BASE;
export const POLL_INTERVAL_MS: number = Number(import.meta.env.VITE_POLL_INTERVAL_MS || 3000);
