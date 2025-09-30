export type EngineOption = 'edge' | 'coqui' | 'piper' | string;
export type FootnoteMode = 'inline' | 'chapter_end' | 'skip';

export interface ConversionFormValues {
  file: File;
  engine: EngineOption;
  voice?: string;
  chapters?: string;
  footnoteMode: FootnoteMode;
  language?: string;
}

export type JobState = 'queued' | 'running' | 'finished' | 'failed';

export interface DownloadAsset {
  name: string;
  url: string;
  durationSeconds?: number;
  sizeBytes?: number;
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
}

export interface ConversionState {
  jobId?: string;
  phase: 'idle' | 'submitting' | 'polling' | 'success' | 'error';
  log: StatusEntry[];
  downloads: DownloadAsset[];
  error?: string;
  etaSeconds?: number | null;
  summary?: ConversionSummary;
}
