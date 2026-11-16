import { lazy } from 'react';

// Lazy load heavy components
export const ConversionForm = lazy(() => import('./components/ConversionForm'));

export const DownloadsPanel = lazy(() => import('./components/DownloadsPanel'));

export const StatusPanel = lazy(() => import('./components/StatusPanel'));

export const RecentJobsPanel = lazy(() => import('./components/RecentJobsPanel'));

export const ResumableJobsPanel = lazy(() => import('./components/ResumableJobsPanel'));

export const QuickQueueAdder = lazy(() => import('./components/QuickQueueAdder'));

export const ActiveConversionBanner = lazy(() => import('./components/ActiveConversionBanner'));

export const ReadyDownloadsList = lazy(() =>
  import('./components/ReadyDownloadsList').then((m) => ({
    default: m.default,
  })),
);

export const QueueDisplay = lazy(() => import('./components/QueueDisplay'));

export const SystemStatsPanel = lazy(() => import('./components/SystemStatsPanel'));

export const TelemetryPanel = lazy(() => import('./components/TelemetryPanel'));

export const ConversionHistoryPanel = lazy(() => import('./components/ConversionHistoryPanel'));

export const ConfirmDialog = lazy(() => import('./components/ConfirmDialog'));

// Loading fallback component
export const ComponentFallback = () => <div style={{ minHeight: '100px' }} />;

export type HfNotificationVariant = 'info' | 'success' | 'error';

export interface HfNotificationEntry {
  id: number;
  title: string;
  body?: string;
  variant: HfNotificationVariant;
}

export interface HfNotificationPayload {
  title: string;
  body?: string;
  variant?: HfNotificationVariant;
  durationMs?: number;
}

export const HIDDEN_RECENT_KEY = 'ebook-tts-hidden-recent';

export const HIDDEN_RESUMABLE_KEY = 'ebook-tts-hidden-resumable';
