import { useCallback, useEffect } from 'react';
import type { ApplicationStateScope } from './useApplicationState';
import type { ApplicationNotificationsScope } from './useApplicationNotifications';

type BackendRestartDialogInput = Pick<
  ApplicationStateScope,
  | 'isHelpOpen'
  | 'setIsHelpOpen'
  | 'isRestartingBackend'
  | 'restartOptionsRef'
  | 'setRestartDialog'
  | 'restartDialog'
  | 'setIsRestartingBackend'
  | 'restartBackend'
  | 't'
  | 'batchHistory'
  | 'notifiedBatchJobsRef'
> &
  Pick<ApplicationNotificationsScope, 'notifyUser'>;

export function useBackendRestartDialog({
  isHelpOpen,
  setIsHelpOpen,
  isRestartingBackend,
  restartOptionsRef,
  setRestartDialog,
  restartDialog,
  setIsRestartingBackend,
  restartBackend,
  notifyUser,
  t,
  batchHistory,
  notifiedBatchJobsRef,
}: BackendRestartDialogInput) {
  useEffect(() => {
    if (!isHelpOpen) {
      return;
    }
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        setIsHelpOpen(false);
      }
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => {
      window.removeEventListener('keydown', handleKeyDown);
    };
  }, [isHelpOpen]);

  const handleRestartBackend = useCallback(() => {
    if (isRestartingBackend) {
      return;
    }
    restartOptionsRef.current = { keepCache: false, keepFinished: false };
    setRestartDialog('confirm');
  }, [isRestartingBackend]);

  const handleRestartDialogConfirm = useCallback(async () => {
    if (restartDialog === 'confirm') {
      setRestartDialog('cache');
    } else if (restartDialog === 'cache') {
      restartOptionsRef.current.keepCache = true;
      setRestartDialog('finished');
    } else if (restartDialog === 'finished') {
      restartOptionsRef.current.keepFinished = true;
      setRestartDialog(null);
      try {
        setIsRestartingBackend(true);
        await restartBackend({
          keep_cache: restartOptionsRef.current.keepCache,
          keep_finished: restartOptionsRef.current.keepFinished,
        });
        notifyUser(t.layout.restartNotifyTitle, t.layout.restartNotifyBody, 'info');
      } catch (error) {
        console.error('[App] Failed to restart backend:', error);
        setIsRestartingBackend(false);
        notifyUser(t.layout.restartNotifyTitle, t.layout.restartErrorBody, 'error');
      }
    }
  }, [
    restartDialog,
    notifyUser,
    restartBackend,
    t.layout.restartNotifyTitle,
    t.layout.restartNotifyBody,
    t.layout.restartErrorBody,
  ]);

  const handleRestartDialogCancel = useCallback(async () => {
    if (restartDialog === 'confirm') {
      setRestartDialog(null);
    } else if (restartDialog === 'cache') {
      restartOptionsRef.current.keepCache = false;
      setRestartDialog('finished');
    } else if (restartDialog === 'finished') {
      restartOptionsRef.current.keepFinished = false;
      setRestartDialog(null);
      try {
        setIsRestartingBackend(true);
        await restartBackend({
          keep_cache: restartOptionsRef.current.keepCache,
          keep_finished: restartOptionsRef.current.keepFinished,
        });
        notifyUser(t.layout.restartNotifyTitle, t.layout.restartNotifyBody, 'info');
      } catch (error) {
        console.error('[App] Failed to restart backend:', error);
        setIsRestartingBackend(false);
        notifyUser(t.layout.restartNotifyTitle, t.layout.restartErrorBody, 'error');
      }
    }
  }, [
    restartDialog,
    notifyUser,
    restartBackend,
    t.layout.restartNotifyTitle,
    t.layout.restartNotifyBody,
    t.layout.restartErrorBody,
  ]);

  const handleRestartDialogClose = useCallback(() => {
    setRestartDialog(null);
  }, []);

  useEffect(() => {
    batchHistory.forEach((job) => {
      if (!job.jobId || notifiedBatchJobsRef.current.has(job.jobId)) {
        return;
      }
      notifiedBatchJobsRef.current.add(job.jobId);
      const body = job.bookTitle
        ? t.downloads.readyNotificationBody(job.bookTitle)
        : t.downloads.readyNotificationBodyFallback;
      notifyUser(t.downloads.readyNotificationTitle, body, 'success');
    });
  }, [
    batchHistory,
    notifyUser,
    t.downloads.readyNotificationBody,
    t.downloads.readyNotificationBodyFallback,
    t.downloads.readyNotificationTitle,
  ]);

  return {
    handleRestartBackend,
    handleRestartDialogConfirm,
    handleRestartDialogCancel,
    handleRestartDialogClose,
  };
}

export type BackendRestartDialogScope = ReturnType<typeof useBackendRestartDialog>;
