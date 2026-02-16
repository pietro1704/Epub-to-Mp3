export type EngineOption = "edge" | "coqui" | "piper" | string;
export type FootnoteMode = "inline" | "chapter_end" | "skip";

export interface ConversionFormValues {
  file: File | null;
  fileName?: string;
  uploadId?: string;
  engine: EngineOption;
  voice?: string;
  model?: string;
  chapters?: string;
  sections?: string;
  fromChapterToEnd?: string;
  fromChapterToChapter?: string;
  priority?: string;
  footnoteMode: FootnoteMode;
  language?: string;
  formattingCues?: boolean;
  noParallel?: boolean;
  maxPerformance?: boolean;
  parallelSlots?: number;
  chapterStallSeconds?: number;
  edgeNetworkTier?: "slow" | "medium" | "fast" | "ultra";
  edgeChunkChars?: number;
  edgeMaxSegmentSeconds?: number;
  edgeEnableParallel?: boolean;
  edgeAutoTune?: boolean;
  edgeStableMode?: boolean;
  coquiChunkChars?: number;
  coquiMaxWorkers?: number;
  coquiSafeMode?: boolean;
  piperMaxProcs?: number;
  bitrate?: string;
  sampleRate?: number;
  channels?: number;
  clearCache?: boolean;
  forceReprocess?: boolean;
  filterChapters?: boolean;
  verbose?: boolean;
  useLanguageDetection?: boolean;
  prioritizePrimaryLanguage?: boolean;
  healthCheckIntervalSeconds?: number;
  healthCheckSlowEdgeCps?: number;
  healthCheckSlowCps?: number;
  healthCheckHighCpu?: number;
  healthCheckHighMem?: number;
  healthCheckOkCpu?: number;
  healthCheckOkMem?: number;
  healthCheckSlowStreak?: number;
  uiLanguage?: string;
}

export type ConversionTemplate = Omit<
  ConversionFormValues,
  "file" | "fileName" | "uploadId"
>;

export interface SubmitBatchOptions {
  batchQueue?: ConversionFormValues[];
}

export type JobState =
  | "queued"
  | "running"
  | "finished"
  | "failed"
  | "interrupted"
  | "cancelling"
  | "cancelled";

export interface DownloadAsset {
  name: string;
  url: string;
  durationSeconds?: number;
  sizeBytes?: number;
}

export interface AudioChunkEntry {
  index: number;
  file: string;
  url: string;
  durationSeconds?: number;
  text?: string;
}

export interface ChapterStreamManifest {
  jobId: string;
  chapterIndex: number;
  baseUrl: string;
  chunks: AudioChunkEntry[];
  updatedAt?: number;
}

export type ChapterProgressStatus =
  | "pending"
  | "processing"
  | "completed"
  | "skipped"
  | "failed"
  | "cancelled"
  | "retrying";

export interface ChapterProgressEntry {
  index: number;
  name: string;
  status: ChapterProgressStatus;
  engine?: string;
  elapsedSeconds?: number;
  charsPerSecond?: number;
  downloadUrl?: string;
  // Retry information
  retryCount?: number;
  maxRetries?: number;
  retryReason?: string;
  paramAdjustment?: string;
}

// Engine status for model loading/initialization
export type EngineLoadingStatus =
  | "idle"
  | "downloading"
  | "loading"
  | "ready"
  | "error";

export interface EngineStatus {
  engine: string;
  status: EngineLoadingStatus;
  message?: string;
  progress?: number; // 0-100 for download progress
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
  startedAt?: string;
  completedAt?: string;
  totalElapsedSeconds?: number | null;
  detectedLanguage?: string;
  chaptersTotal?: number;
  chaptersCompleted?: number;
  currentChapter?: string;
  progressPercent?: number | null;
  chapterProgress?: ChapterProgressEntry[];
  totalSegments?: number;
  completedSegments?: number;
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
  lastActivityAt?: number;
  noParallel?: boolean;
  engineStatus?: EngineStatus;
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
  engineStatus?: EngineStatus;
}

export interface ConversionState {
  jobId?: string;
  phase:
    | "idle"
    | "submitting"
    | "polling"
    | "success"
    | "error"
    | "cancelling"
    | "cancelled";
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
  startedAt?: string;
  completedAt?: string;
  totalDurationSeconds?: number;
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
  startedAt?: string;
  completedAt?: string;
  totalDurationSeconds?: number;
}
