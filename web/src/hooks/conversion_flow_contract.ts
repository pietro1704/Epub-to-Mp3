import { RestartOptions, UploadResponse } from '../services/ConversionService';
import {
  ConversionFormValues,
  ConversionState,
  RecentJobEntry,
  SubmitBatchOptions,
} from '../types/conversion';

export interface UseConversionFlowApi {
  state: ConversionState;
  submit: (values: ConversionFormValues, options?: SubmitBatchOptions) => Promise<void>;
  enqueue: (jobs: ConversionFormValues[]) => Promise<void>;
  resume: (jobId: string) => Promise<void>;
  reset: () => void;
  cancel: () => Promise<boolean>;
  skipCurrent: () => Promise<boolean>;
  cancelJobById: (jobId: string) => Promise<void>;
  removeCachedJob: (jobId: string) => void;
  isBusy: boolean;
  cachedJobs: Array<{
    jobId: string;
    fileName: string;
    timestamp: number;
    engine?: string;
    voice?: string;
    language?: string;
    pendingQueueCount?: number;
  }>;
  cachedJobsLoading: boolean;
  uploadFile: (file: File) => Promise<UploadResponse>;
  recentJobs: RecentJobEntry[];
  apiAvailable: boolean;
  healthStatus: 'unknown' | 'ok' | 'fail' | 'restarting';
  notifyServerReady: () => void;
  queue: ConversionFormValues[];
  queuePaused: boolean;
  resumeQueue: () => void;
  clearQueue: () => void;
  reorderQueue: (fromIndex: number, toIndex: number) => void;
  restartBackend: (options?: RestartOptions) => Promise<void>;
  savedBatch: ConversionFormValues[] | null;
  resumeBatch: (queue: ConversionFormValues[]) => Promise<void>;
  dismissSavedBatch: () => void;
}
