import type { ConversionState } from "../types/conversion";

const CACHE_KEY_PREFIX = "ebook-tts-cache";
const CACHE_VERSION = 1;

export interface CachedConversion {
  version: number;
  jobId: string;
  timestamp: number;
  fileName: string;
  state: ConversionState;
}

export class ConversionCache {
  private readonly PENDING_BATCH_KEY = "ebook-tts-pending-batch";

  savePendingBatch(queue: unknown[]): void {
    try {
      localStorage.setItem(
        this.PENDING_BATCH_KEY,
        JSON.stringify({ queue, savedAt: Date.now() }),
      );
    } catch (error) {
      console.warn("[ConversionCache] Failed to save pending batch:", error);
    }
  }

  loadPendingBatch(): unknown[] | null {
    try {
      const data = localStorage.getItem(this.PENDING_BATCH_KEY);
      if (!data) return null;
      const parsed = JSON.parse(data);
      if (Array.isArray(parsed?.queue) && parsed.queue.length > 0) {
        return parsed.queue;
      }
    } catch (error) {
      console.warn("[ConversionCache] Failed to load pending batch:", error);
    }
    return null;
  }

  clearPendingBatch(): void {
    try {
      localStorage.removeItem(this.PENDING_BATCH_KEY);
    } catch (error) {
      console.warn("[ConversionCache] Failed to clear pending batch:", error);
    }
  }

  private getKey(jobId: string): string {
    return `${CACHE_KEY_PREFIX}:${jobId}`;
  }

  private getAllKeys(): string[] {
    const keys: string[] = [];
    for (let i = 0; i < localStorage.length; i++) {
      const key = localStorage.key(i);
      if (key?.startsWith(CACHE_KEY_PREFIX)) {
        keys.push(key);
      }
    }
    return keys;
  }

  save(jobId: string, fileName: string, state: ConversionState): void {
    try {
      const cached: CachedConversion = {
        version: CACHE_VERSION,
        jobId,
        timestamp: Date.now(),
        fileName,
        state,
      };
      localStorage.setItem(this.getKey(jobId), JSON.stringify(cached));
    } catch (error) {
      console.warn("[ConversionCache] Failed to save:", error);
    }
  }

  load(jobId: string): CachedConversion | null {
    try {
      const data = localStorage.getItem(this.getKey(jobId));
      if (!data) return null;
      const cached = JSON.parse(data) as CachedConversion;
      if (cached.version !== CACHE_VERSION) return null;
      return cached;
    } catch (error) {
      console.warn("[ConversionCache] Failed to load:", error);
      return null;
    }
  }

  remove(jobId: string): void {
    try {
      localStorage.removeItem(this.getKey(jobId));
    } catch (error) {
      console.warn("[ConversionCache] Failed to remove:", error);
    }
  }

  listAll(): CachedConversion[] {
    const keys = this.getAllKeys();
    const conversions: CachedConversion[] = [];

    for (const key of keys) {
      try {
        const data = localStorage.getItem(key);
        if (!data) continue;
        const cached = JSON.parse(data) as CachedConversion;
        if (cached.version === CACHE_VERSION) {
          conversions.push(cached);
        }
      } catch (error) {
        console.warn("[ConversionCache] Failed to parse cached item:", error);
      }
    }

    // Sort by timestamp, newest first
    return conversions.sort((a, b) => b.timestamp - a.timestamp);
  }

  clearAll(): void {
    const keys = this.getAllKeys();
    for (const key of keys) {
      localStorage.removeItem(key);
    }
  }

  // Remove old cached conversions (older than 7 days)
  cleanup(maxAgeMs: number = 7 * 24 * 60 * 60 * 1000): void {
    const now = Date.now();
    const conversions = this.listAll();

    for (const cached of conversions) {
      if (now - cached.timestamp > maxAgeMs) {
        this.remove(cached.jobId);
      }
    }
  }
}

export const conversionCache = new ConversionCache();
