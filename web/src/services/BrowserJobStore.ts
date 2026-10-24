import type { BookTextDocument, JobSnapshot, TtsPreferences } from '../types/conversion';
import type { BrowserAudioReceipt } from './BrowserConversionRuntime';

export interface StoredBrowserAudio {
  chunks?: Array<{
    index: number;
    text?: string;
    durationSeconds?: number;
    byteOffset: number;
    byteLength: number;
  }>;
  cacheIdentity?: string;
  textOffset?: number;
  chapterIndex: number;
  name: string;
  blob: Blob;
  ttsReceipts?: BrowserAudioReceipt[];
}
export interface StoredBrowserJob {
  listeningPosition?: { version: 2; chapter_index: number; text_offset: number };
  jobId: string;
  snapshot: JobSnapshot;
  document: BookTextDocument;
  preferences: TtsPreferences;
  language: string;
  policyState?: string;
  audio: StoredBrowserAudio[];
}
export interface BrowserJobStore {
  list(): Promise<StoredBrowserJob[]>;
  save(job: StoredBrowserJob): Promise<void>;
  remove(jobId: string): Promise<void>;
}

/** Blobs are immutable; cloning state separately also works in test DOMs. */
function copyJob(job: StoredBrowserJob): StoredBrowserJob {
  return {
    jobId: job.jobId,
    snapshot: structuredClone(job.snapshot),
    document: structuredClone(job.document),
    preferences: structuredClone(job.preferences),
    language: job.language,
    ...(job.listeningPosition ? { listeningPosition: structuredClone(job.listeningPosition) } : {}),
    ...(job.policyState ? { policyState: job.policyState } : {}),
    audio: job.audio.map((audio) => ({
      ...audio,
      blob: audio.blob,
      ...(audio.chunks ? { chunks: structuredClone(audio.chunks) } : {}),
      ...(audio.ttsReceipts ? { ttsReceipts: structuredClone(audio.ttsReceipts) } : {}),
    })),
  };
}
function storageError(error: unknown): Error {
  if (error instanceof Error && error.name === 'QuotaExceededError') {
    return new Error(
      'Browser audiobook storage quota exceeded. Free space and retry; conversion progress could not be saved.',
      { cause: error },
    );
  }
  return new Error(
    'Browser audiobook storage is unavailable. Enable IndexedDB storage for this site and retry.',
    { cause: error },
  );
}

/** Durable browser storage; success means the transaction actually committed. */
export class IndexedDBBrowserJobStore implements BrowserJobStore {
  private connection: Promise<IDBDatabase> | undefined;
  constructor(private readonly factory: IDBFactory | undefined = globalThis.indexedDB) {}

  private open(): Promise<IDBDatabase> {
    if (this.connection) return this.connection;
    this.connection = new Promise<IDBDatabase>((resolve, reject) => {
      if (!this.factory) {
        reject(storageError(new Error('IndexedDB is not available')));
        return;
      }
      let rejected = false;
      let request: IDBOpenDBRequest;
      try {
        request = this.factory.open('ebook-tts.jobs.v1', 1);
      } catch (error) {
        reject(storageError(error));
        return;
      }
      request.onupgradeneeded = () => {
        if (!request.result.objectStoreNames.contains('jobs'))
          request.result.createObjectStore('jobs', { keyPath: 'jobId' });
      };
      request.onerror = () => {
        rejected = true;
        reject(storageError(request.error));
      };
      request.onblocked = () => {
        rejected = true;
        reject(
          new Error(
            'Browser audiobook storage is blocked by another tab. Close the other tab and retry.',
          ),
        );
      };
      request.onsuccess = () => {
        if (rejected) {
          request.result.close();
          return;
        }
        const database = request.result;
        database.onversionchange = () => {
          database.close();
          this.connection = undefined;
        };
        resolve(database);
      };
    }).catch((error) => {
      this.connection = undefined;
      throw error;
    });
    return this.connection;
  }

  private async transaction<T>(
    mode: IDBTransactionMode,
    operation: (store: IDBObjectStore) => IDBRequest<T>,
  ): Promise<T> {
    const database = await this.open();
    return new Promise<T>((resolve, reject) => {
      let transaction: IDBTransaction;
      try {
        transaction = database.transaction('jobs', mode);
      } catch (error) {
        reject(storageError(error));
        return;
      }
      let result: T;
      transaction.oncomplete = () => resolve(result);
      transaction.onabort = () => reject(storageError(transaction.error));
      transaction.onerror = () => reject(storageError(transaction.error));
      try {
        const request = operation(transaction.objectStore('jobs'));
        request.onsuccess = () => {
          result = request.result;
        };
        request.onerror = () => reject(storageError(request.error));
      } catch (error) {
        try {
          transaction.abort();
        } catch {
          /* A transaction may already be inactive. */
        }
        reject(storageError(error));
      }
    });
  }

  async list(): Promise<StoredBrowserJob[]> {
    const jobs = await this.transaction<StoredBrowserJob[]>('readonly', (store) => store.getAll());
    return jobs.map(copyJob);
  }
  async save(job: StoredBrowserJob): Promise<void> {
    const immutable = copyJob(job);
    await this.transaction<IDBValidKey>('readwrite', (store) => store.put(immutable));
  }
  async remove(jobId: string): Promise<void> {
    await this.transaction<undefined>('readwrite', (store) => store.delete(jobId));
  }
}

/** Explicit test adapter; production never silently falls back to this store. */
export class MemoryBrowserJobStore implements BrowserJobStore {
  private readonly jobs = new Map<string, StoredBrowserJob>();
  async list(): Promise<StoredBrowserJob[]> {
    return [...this.jobs.values()].map(copyJob);
  }
  async save(job: StoredBrowserJob): Promise<void> {
    this.jobs.set(job.jobId, copyJob(job));
  }
  async remove(jobId: string): Promise<void> {
    this.jobs.delete(jobId);
  }
}
