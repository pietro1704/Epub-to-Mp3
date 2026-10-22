import { useEffect } from 'react';
import { isTauri, sendNotification } from './lib/tauri';
import type { RecentJobEntry } from './types/conversion';
import type { ApplicationStateScope } from './useApplicationState';
import type { WorkspaceIntentsScope } from './useWorkspaceIntents';
import type { PlaybackWorkspaceScope } from './usePlaybackWorkspace';
import type { ApplicationNotificationsScope } from './useApplicationNotifications';

type CompletedConversionEffectsInput = Pick<
  ApplicationStateScope,
  | 'state'
  | 'activeTab'
  | 'setActiveTab'
  | 'userSelectedTab'
  | 'setUserSelectedTab'
  | 'lastCompletedJobIdRef'
  | 't'
  | 'setBatchHistory'
  | 'manualDownloadOverrideRef'
  | 'viewingRecentJob'
  | 'setViewingRecentJob'
  | 'lastPhaseRef'
> &
  Pick<WorkspaceIntentsScope, 'hasDownloads'> &
  Pick<PlaybackWorkspaceScope, 'readyDownloadJobs'> &
  Pick<ApplicationNotificationsScope, 'notifyUser'>;

export function useCompletedConversionEffects({
  state,
  activeTab,
  setActiveTab,
  userSelectedTab,
  setUserSelectedTab,
  hasDownloads,
  lastCompletedJobIdRef,
  t,
  setBatchHistory,
  manualDownloadOverrideRef,
  readyDownloadJobs,
  viewingRecentJob,
  setViewingRecentJob,
  lastPhaseRef,
  notifyUser,
}: CompletedConversionEffectsInput) {
  useEffect(() => {
    if (state.phase === 'cancelled') {
      if (activeTab !== 'setup') {
        setActiveTab('setup');
      }
      if (userSelectedTab) {
        setUserSelectedTab(false);
      }
      return;
    }
    if (userSelectedTab) {
      return;
    }
    if (state.phase === 'success' || (hasDownloads && state.phase !== 'error')) {
      if (activeTab !== 'downloads') {
        setActiveTab('downloads');
      }
      return;
    }
    if (state.phase === 'error') {
      if (activeTab !== 'progress') {
        setActiveTab('progress');
      }
      return;
    }
    if (state.phase === 'submitting' && activeTab !== 'progress') {
      setActiveTab('progress');
      return;
    }
    if (state.phase === 'polling' && activeTab !== 'progress') {
      setActiveTab('progress');
    }
  }, [state.phase, hasDownloads, activeTab, userSelectedTab]);

  useEffect(() => {
    if (typeof window === 'undefined' || !('Notification' in window)) {
      return;
    }
    if (Notification.permission === 'default') {
      Notification.requestPermission().catch(() => {});
    }
  }, []);

  useEffect(() => {
    if (state.phase !== 'success') {
      return;
    }
    if (!state.jobId || !Array.isArray(state.downloads) || state.downloads.length === 0) {
      return;
    }
    if (lastCompletedJobIdRef.current === state.jobId) {
      return;
    }
    const resolvedTitle = state.bookTitle?.trim() || t.status.bookFallbackTitle;
    const mp3Count = state.downloads.filter((asset) =>
      asset.name.toLowerCase().endsWith('.mp3'),
    ).length;
    const chapterCount = mp3Count || state.summary?.chaptersCompleted || 0;
    const downloadUrl =
      state.downloads.find((asset) => asset.name.toLowerCase().endsWith('.zip'))?.url ??
      state.downloads[0]?.url;
    const completedAtIso = state.completedAt ?? new Date().toISOString();
    const entry: RecentJobEntry = {
      jobId: state.jobId,
      state: 'finished',
      bookTitle: resolvedTitle,
      fileName: resolvedTitle,
      savedAt: completedAtIso,
      outputs: state.downloads,
      downloadUrl,
      chaptersCompleted: state.summary?.chaptersCompleted ?? chapterCount,
      chaptersTotal: state.summary?.chaptersTotal ?? (chapterCount || undefined),
      progressPercent: 100,
      engine: state.engine,
      voice: state.voice,
      language: state.language ?? state.summary?.detectedLanguage,
      formattingCues: state.speakFormattingCues,
      uiLanguage: state.uiLanguage,
      hasOutputs: true,
      canResume: false,
      startedAt: state.startedAt,
      completedAt: completedAtIso,
      totalDurationSeconds: state.totalDurationSeconds,
    };
    setBatchHistory((prev) => {
      const next = [entry, ...prev.filter((job) => job.jobId !== entry.jobId)];
      return next.slice(0, 5);
    });
    manualDownloadOverrideRef.current = false;
    lastCompletedJobIdRef.current = state.jobId;
    // OS notification — always in Tauri (app may be minimised or behind another window)
    if (isTauri()) {
      sendNotification(t.downloads.readyNotificationTitle, resolvedTitle);
    }
  }, [
    state.bookTitle,
    state.downloads,
    state.engine,
    state.language,
    state.phase,
    state.summary,
    state.jobId,
    state.speakFormattingCues,
    state.uiLanguage,
    state.voice,
    t.status.bookFallbackTitle,
  ]);

  useEffect(() => {
    if (!readyDownloadJobs.length) {
      return;
    }
    const currentJob = state.jobId
      ? readyDownloadJobs.find((job) => job.jobId === state.jobId)
      : undefined;
    if (state.phase === 'success' && currentJob) {
      if (
        !viewingRecentJob ||
        viewingRecentJob.jobId !== currentJob.jobId ||
        manualDownloadOverrideRef.current
      ) {
        manualDownloadOverrideRef.current = false;
        setViewingRecentJob(currentJob);
      }
      return;
    }
    if (manualDownloadOverrideRef.current) {
      return;
    }
    const latest = readyDownloadJobs[0];
    if (!viewingRecentJob || viewingRecentJob.jobId !== latest.jobId) {
      setViewingRecentJob(latest);
    }
  }, [readyDownloadJobs, state.jobId, state.phase, viewingRecentJob]);

  useEffect(() => {
    if (state.phase === lastPhaseRef.current) {
      return;
    }
    if (state.phase === 'error') {
      notifyUser(
        t.flow.notificationErrorTitle,
        state.error || t.flow.notificationErrorBody,
        'error',
      );
    }
    if (state.phase === 'cancelled') {
      notifyUser(t.flow.notificationCancelTitle, t.flow.notificationCancelBody, 'info');
    }
    lastPhaseRef.current = state.phase;
  }, [
    notifyUser,
    state.error,
    state.phase,
    t.flow.notificationCancelBody,
    t.flow.notificationCancelTitle,
    t.flow.notificationErrorBody,
    t.flow.notificationErrorTitle,
  ]);
}

export type CompletedConversionEffectsScope = ReturnType<typeof useCompletedConversionEffects>;
