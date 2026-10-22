import { useCallback, useEffect, useMemo } from 'react';
import {
  HfNotificationVariant,
  HfNotificationEntry,
  HfNotificationPayload,
} from './ApplicationPresentation';
import type { ApplicationStateScope } from './useApplicationState';
import type { PlaybackWorkspaceScope } from './usePlaybackWorkspace';

type ApplicationNotificationsInput = Pick<
  ApplicationStateScope,
  | 'setHfNotifications'
  | 'isHfSpace'
  | 'hfNotificationCounterRef'
  | 'recentJobs'
  | 'hiddenRecentIds'
  | 'state'
  | 'queuePlanTotal'
  | 'setQueuePlanTotal'
  | 'cachedJobs'
  | 'hiddenResumableIds'
> &
  Pick<PlaybackWorkspaceScope, 'queueForDisplay'>;

export function useApplicationNotifications({
  setHfNotifications,
  isHfSpace,
  hfNotificationCounterRef,
  recentJobs,
  hiddenRecentIds,
  state,
  queuePlanTotal,
  queueForDisplay,
  setQueuePlanTotal,
  cachedJobs,
  hiddenResumableIds,
}: ApplicationNotificationsInput) {
  const dismissHfNotification = useCallback((id: number) => {
    setHfNotifications((prev) => prev.filter((entry) => entry.id !== id));
  }, []);

  const pushHfNotification = useCallback(
    (payload: HfNotificationPayload) => {
      if (!isHfSpace) {
        return false;
      }
      hfNotificationCounterRef.current += 1;
      const id = hfNotificationCounterRef.current;
      const entry: HfNotificationEntry = {
        id,
        title: payload.title,
        body: payload.body,
        variant: payload.variant ?? 'info',
      };
      setHfNotifications((prev) => [...prev, entry]);
      if (typeof window !== 'undefined') {
        window.setTimeout(() => dismissHfNotification(id), payload.durationMs ?? 5000);
      }
      return true;
    },
    [dismissHfNotification, isHfSpace],
  );

  const notifyUser = useCallback(
    (title: string, body: string, variant: HfNotificationVariant = 'info') => {
      if (
        typeof window !== 'undefined' &&
        'Notification' in window &&
        Notification.permission === 'granted'
      ) {
        new Notification(title, { body });
        return;
      }
      if (isHfSpace) {
        pushHfNotification({ title, body, variant });
      }
    },
    [isHfSpace, pushHfNotification],
  );

  // Filter recent jobs to show only completed ones
  const completedRecentJobs = useMemo(() => {
    return recentJobs.filter(
      (job) => job.state === 'finished' && job.hasOutputs && !hiddenRecentIds.has(job.jobId),
    );
  }, [hiddenRecentIds, recentJobs]);

  useEffect(() => {
    const activeJobCount = state.phase === 'polling' || state.phase === 'submitting' ? 1 : 0;
    if (queuePlanTotal === 0 && queueForDisplay.length + activeJobCount > 0) {
      setQueuePlanTotal(queueForDisplay.length + activeJobCount);
    }
  }, [queueForDisplay.length, queuePlanTotal, state.phase]);

  const currentJobForQueue = useMemo(() => {
    if (state.phase !== 'polling' && state.phase !== 'submitting') {
      return undefined;
    }
    return {
      fileName: state.bookTitle,
      bookTitle: state.bookTitle,
    };
  }, [state.phase, state.bookTitle]);

  const visibleCachedJobs = useMemo(
    () => cachedJobs.filter((job) => !hiddenResumableIds.has(job.jobId)),
    [cachedJobs, hiddenResumableIds],
  );

  return {
    currentJobForQueue,
    notifyUser,
    visibleCachedJobs,
    completedRecentJobs,
    dismissHfNotification,
  };
}

export type ApplicationNotificationsScope = ReturnType<typeof useApplicationNotifications>;
