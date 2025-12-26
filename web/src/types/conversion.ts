export type EngineOption = 'edge' | 'coqui' | 'piper' | string;
export type FootnoteMode = 'inline' | 'chapter_end' | 'skip';

export interface ConversionFormValues {
  file: File | null;
  fileName?: string;
  uploadId?: string;
  engine: EngineOption;
  voice?: string;
  chapters?: string;
  priority?: string;
  footnoteMode: FootnoteMode;
  language?: string;
  formattingCues?: boolean;
  uiLanguage?: string;
}

export type ConversionTemplate = Omit<ConversionFormValues, 'file' | 'fileName' | 'uploadId'>;

export interface SubmitBatchOptions {
  batchQueue?: ConversionFormValues[];
}

export type JobState = 'queued' | 'running' | 'finished' | 'failed' | 'interrupted' | 'cancelling' | 'cancelled';

export interface DownloadAsset {
  name: string;
  url: string;
  durationSeconds?: number;
  sizeBytes?: number;
}

export type ChapterProgressStatus = 'pending' | 'processing' | 'completed' | 'skipped' | 'failed' | 'cancelled';

export interface ChapterProgressEntry {
  index: number;
  name: string;
  status: ChapterProgressStatus;
  elapsedSeconds?: number;
  charsPerSecond?: number;
}

export interface JobSnapshot {
  jobId: string;
  state: JobState;
  events?: string[];
  outputs?: DownloadAsset[];
  error?: string;
  updatedAt?: string;
  etaSeconds?: number | null;
  progress?: number | null;
  detectedLanguage?: string;
  chaptersTotal?: number;
  chaptersCompleted?: number;
  currentChapter?: string;
  progressPercent?: number | null;
  chapterProgress?: ChapterProgressEntry[];
  bookTitle?: string;
  bookAuthor?: string;
  coverUrl?: string;
  coverMimeType?: string;
  parallelSlots?: number;
  parallelActive?: number;
  rawLog?: string[];
  statusHint?: string;
  engine?: string;
  voice?: string;
  language?: string;
  formattingCues?: boolean;
  uiLanguage?: string;
}

export interface StatusEntry {
  id: string;
  message: string;
  timestamp: string;
}

export interface ConversionSummary {
  detectedLanguage?: string;
  chaptersTotal?: number;
  chaptersCompleted?: number;
  currentChapter?: string;
  progressPercent?: number | null;
  chapterProgress?: ChapterProgressEntry[];
  parallelSlots?: number;
  parallelActive?: number;
  statusHint?: string;
}

export interface ConversionState {
  jobId?: string;
  phase: 'idle' | 'submitting' | 'polling' | 'success' | 'error' | 'cancelling' | 'cancelled';
  log: StatusEntry[];
  downloads: DownloadAsset[];
  error?: string;
  etaSeconds?: number | null;
  summary?: ConversionSummary;
  cliCommand?: string;
  bookTitle?: string;
  bookAuthor?: string;
  coverUrl?: string;
  rawLog: string[];
  engine?: string;
  voice?: string;
  language?: string;
  uiLanguage?: string;
  speakFormattingCues?: boolean;
  pendingBatchQueue?: ConversionFormValues[];
}

export interface RecentJobEntry {
  jobId: string;
  state: string;
  bookTitle: string;
  fileName: string;
  savedAt?: string;
  chaptersCompleted?: number;
  chaptersTotal?: number;
  progressPercent?: number | null;
  downloadUrl?: string | null;
  hasOutputs?: boolean;
  canResume?: boolean;
  outputs?: DownloadAsset[];
  engine?: string;
  voice?: string;
  language?: string;
  formattingCues?: boolean;
  uiLanguage?: string;
}
