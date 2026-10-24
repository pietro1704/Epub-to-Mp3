import type {
  BookTextDocument,
  ChapterStreamManifest,
  JobSnapshot,
  TtsPreferences,
} from '../types/conversion';
import type { StoredBrowserAudio } from './BrowserJobStore';
import type { BrowserSession } from './BrowserConversionRuntime';

export interface BrowserConversionJob {
  snapshot: JobSnapshot;
  document: BookTextDocument;
  preferences: TtsPreferences;
  language: string;
  policyState?: string;
  listeningPosition?: { version: 2; chapter_index: number; text_offset: number };
  listeningEpoch?: number;
  audio: Map<number, StoredBrowserAudio>;
  session?: BrowserSession;
  chunks: Map<number, ChapterStreamManifest>;
  done: Promise<void>;
}
export const terminalBrowserJob = (state: string) =>
  ['finished', 'failed', 'cancelled', 'interrupted'].includes(state);

export function isBrowserJobCancelled(job: BrowserConversionJob): boolean {
  return job.snapshot.state === 'cancelled';
}
