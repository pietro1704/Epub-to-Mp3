import {
  ConversionState,
  DownloadAsset,
  StatusEntry,
  ConversionSummary,
} from '../types/conversion';

export type Action =
  | { type: 'reset' }
  | {
      type: 'start';
      entry: StatusEntry;
      cliCommand?: string;
      cliShell?: ConversionState['cliShell'];
      startedAt?: string;
    }
  | { type: 'job-created'; entry: StatusEntry; jobId: string }
  | { type: 'append-entry'; entry: StatusEntry }
  | {
      type: 'complete';
      entry: StatusEntry;
      downloads: DownloadAsset[];
      completedAt?: string;
      totalDurationSeconds?: number;
    }
  | { type: 'fail'; entry: StatusEntry; error: string; errorCategory?: string }
  | { type: 'cancelling'; entry: StatusEntry }
  | {
      type: 'cancelled';
      entry: StatusEntry;
      error: string;
      errorCategory?: string;
    }
  | {
      type: 'update-meta';
      etaSeconds?: number | null;
      summary?: ConversionSummary;
      details?: Partial<
        Pick<
          ConversionState,
          | 'bookTitle'
          | 'bookAuthor'
          | 'coverUrl'
          | 'engine'
          | 'voice'
          | 'language'
          | 'uiLanguage'
          | 'speakFormattingCues'
        >
      >;
      rawLog?: string[];
      timestamps?: Partial<
        Pick<ConversionState, 'startedAt' | 'completedAt' | 'totalDurationSeconds'>
      >;
    };

export const initialState: ConversionState = {
  phase: 'idle',
  log: [],
  downloads: [],
  error: undefined,
  jobId: undefined,
  etaSeconds: undefined,
  summary: undefined,
  cliCommand: undefined,
  cliShell: undefined,
  bookTitle: undefined,
  bookAuthor: undefined,
  coverUrl: undefined,
  rawLog: [],
  engine: undefined,
  voice: undefined,
  language: undefined,
  uiLanguage: undefined,
  speakFormattingCues: undefined,
  startedAt: undefined,
  completedAt: undefined,
  totalDurationSeconds: undefined,
};

export function reducer(state: ConversionState, action: Action): ConversionState {
  switch (action.type) {
    case 'reset':
      return { ...initialState };
    case 'start':
      return {
        ...initialState,
        phase: 'submitting',
        log: [action.entry],
        cliCommand: action.cliCommand,
        cliShell: action.cliShell,
        startedAt: action.startedAt ?? new Date().toISOString(),
        completedAt: undefined,
        totalDurationSeconds: undefined,
        // Clear metadata from previous uploads to avoid showing wrong book cover
        bookTitle: undefined,
        bookAuthor: undefined,
        coverUrl: undefined,
      };
    case 'job-created':
      return {
        ...state,
        phase: 'polling',
        jobId: action.jobId,
        log: [...state.log, action.entry],
        // Clear summary from previous job to prevent mixing data
        summary: undefined,
      };
    case 'append-entry':
      return {
        ...state,
        log: [...state.log, action.entry],
      };
    case 'complete':
      return {
        ...state,
        phase: 'success',
        downloads: action.downloads,
        log: [...state.log, action.entry],
        error: undefined,
        etaSeconds: 0,
        completedAt: action.completedAt ?? new Date().toISOString(),
        totalDurationSeconds: action.totalDurationSeconds ?? state.totalDurationSeconds,
        summary: state.summary
          ? {
              ...state.summary,
              progressPercent: state.summary.progressPercent ?? 100,
            }
          : state.summary,
      };
    case 'fail':
      return {
        ...state,
        phase: 'error',
        error: action.error,
        errorCategory: action.errorCategory,
        log: [...state.log, action.entry],
        etaSeconds: 0,
        summary: state.summary,
      };
    case 'cancelling':
      return {
        ...state,
        phase: 'cancelling',
        log: [...state.log, action.entry],
      };
    case 'cancelled':
      return {
        ...initialState,
        phase: 'idle',
        error: action.error,
        errorCategory: action.errorCategory,
        log: [...state.log, action.entry],
      };
    case 'update-meta': {
      let nextSummary = state.summary;
      if (action.summary) {
        nextSummary = { ...nextSummary } as ConversionSummary;
        for (const [key, value] of Object.entries(action.summary) as [
          keyof ConversionSummary,
          unknown,
        ][]) {
          if (value !== undefined && value !== null) {
            if (!nextSummary) {
              nextSummary = {} as ConversionSummary;
            }
            let mergedValue = value;
            if (
              (key === 'progressPercent' || key === 'chaptersCompleted') &&
              typeof value === 'number' &&
              typeof nextSummary[key] === 'number'
            ) {
              mergedValue = Math.max(nextSummary[key] as number, value);
            }
            (nextSummary as ConversionSummary)[key] = mergedValue as never;
          }
        }
      }
      const updatedState: ConversionState = {
        ...state,
        etaSeconds:
          typeof action.etaSeconds === 'number'
            ? Math.max(0, action.etaSeconds)
            : action.etaSeconds,
        summary: nextSummary,
      };
      if (action.details) {
        if (action.details.bookTitle !== undefined)
          updatedState.bookTitle = action.details.bookTitle;
        if (action.details.bookAuthor !== undefined)
          updatedState.bookAuthor = action.details.bookAuthor;
        if (action.details.coverUrl !== undefined) updatedState.coverUrl = action.details.coverUrl;
        if (action.details.engine !== undefined) updatedState.engine = action.details.engine;
        if (action.details.voice !== undefined) updatedState.voice = action.details.voice;
        if (action.details.language !== undefined) updatedState.language = action.details.language;
        if (action.details.uiLanguage !== undefined)
          updatedState.uiLanguage = action.details.uiLanguage;
        if (action.details.speakFormattingCues !== undefined) {
          updatedState.speakFormattingCues = action.details.speakFormattingCues;
        }
      }
      if (Array.isArray(action.rawLog)) {
        updatedState.rawLog = action.rawLog;
      }
      if (action.timestamps) {
        if (action.timestamps.startedAt !== undefined)
          updatedState.startedAt = action.timestamps.startedAt ?? updatedState.startedAt;
        if (action.timestamps.completedAt !== undefined)
          updatedState.completedAt = action.timestamps.completedAt ?? updatedState.completedAt;
        if (action.timestamps.totalDurationSeconds !== undefined) {
          updatedState.totalDurationSeconds =
            typeof action.timestamps.totalDurationSeconds === 'number'
              ? Math.max(0, Math.round(action.timestamps.totalDurationSeconds))
              : undefined;
        }
      }
      return updatedState;
    }
    default:
      return state;
  }
}

export function createStatusEntryFactory() {
  let sequence = 0;
  return (message: string): StatusEntry => {
    sequence += 1;
    return {
      id: `status-${sequence}`,
      message,
      timestamp: new Date().toISOString(),
    };
  };
}
