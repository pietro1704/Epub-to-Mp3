import {
  ConversionFormValues,
  JobSnapshot,
  RecentJobEntry,
  ChapterStreamManifest,
  BookTextDocument,
} from '../types/conversion';

export interface PollOptions {
  intervalMs?: number;
  signal?: AbortSignal;
  onSnapshot?: (snapshot: JobSnapshot) => void;
  onStreamStatus?: (status: 'connecting' | 'healthy' | 'fallback') => void;
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

export type FullTextResult =
  | { kind: 'ok'; document: BookTextDocument }
  | { kind: 'pending'; status: number }
  | { kind: 'missing'; status: number }
  | { kind: 'unprocessable'; status: number }
  | { kind: 'error'; status: number }
  | { kind: 'network-error' };

export interface ConversionClient {
  readonly mode?: 'embedded' | 'http';
  submit(request: ConversionFormValues): Promise<{ jobId: string }>;
  fetch(jobId: string, signal?: AbortSignal): Promise<JobSnapshot>;
  poll(jobId: string, options?: PollOptions): Promise<JobSnapshot>;
  getResumableJobs?(): Promise<ResumableJob[] | null>;
  getRecentJobs?(): Promise<RecentJobEntry[] | null>;
  getChapterManifest?(jobId: string, chapterIndex: number): Promise<ChapterStreamManifest | null>;
  getNativePlaybackPolicy?(
    jobId: string,
  ): Promise<{ language: string; voice: string | null } | null>;
  getJobFullText?(jobId: string): Promise<BookTextDocument | null>;
  getJobFullTextResult?(jobId: string): Promise<FullTextResult>;
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
