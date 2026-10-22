import { CSSProperties, Suspense, useCallback } from 'react';
import { QueueDisplay, ComponentFallback } from './ApplicationPresentation';
import type { ApplicationStateScope } from './useApplicationState';
import type { PlaybackWorkspaceScope } from './usePlaybackWorkspace';
import type { ApplicationNotificationsScope } from './useApplicationNotifications';

type QueueDisplayInput = Pick<
  ApplicationStateScope,
  | 'state'
  | 'queuePlanTotal'
  | 'queuePaused'
  | 'resumeQueue'
  | 'clearQueue'
  | 'setQueuePlanTotal'
  | 'reorderQueue'
> &
  Pick<PlaybackWorkspaceScope, 'queueForDisplay'> &
  Pick<ApplicationNotificationsScope, 'currentJobForQueue'>;

export function useQueueDisplay({
  currentJobForQueue,
  queueForDisplay,
  state,
  queuePlanTotal,
  queuePaused,
  resumeQueue,
  clearQueue,
  setQueuePlanTotal,
  reorderQueue,
}: QueueDisplayInput) {
  const renderQueueDisplay = useCallback(
    (style?: CSSProperties) => {
      if (!currentJobForQueue && queueForDisplay.length === 0) {
        return null;
      }
      const activeJobCount = state.phase === 'polling' || state.phase === 'submitting' ? 1 : 0;
      const currentProgressFraction = activeJobCount
        ? Math.min(1, Math.max(0, (state.summary?.progressPercent ?? 0) / 100))
        : 0;
      const pendingJobs = queueForDisplay.length;
      const totalJobs = queuePlanTotal || pendingJobs + activeJobCount;
      const completedJobs = Math.max(0, totalJobs - (pendingJobs + activeJobCount));
      const overallPercent =
        totalJobs > 0 ? ((completedJobs + currentProgressFraction) / totalJobs) * 100 : null;

      return (
        <div style={{ margin: '1.5rem 0', ...style }}>
          <Suspense fallback={<ComponentFallback />}>
            <QueueDisplay
              currentJob={currentJobForQueue}
              queue={queueForDisplay}
              queuePaused={queuePaused}
              onResumeQueue={queuePaused ? resumeQueue : undefined}
              onClearQueue={
                queueForDisplay.length > 0
                  ? () => {
                      clearQueue();
                      setQueuePlanTotal(0);
                    }
                  : undefined
              }
              onReorderQueue={queueForDisplay.length > 1 ? reorderQueue : undefined}
              totalJobs={totalJobs}
              overallPercent={overallPercent}
            />
          </Suspense>
        </div>
      );
    },
    [
      clearQueue,
      currentJobForQueue,
      queueForDisplay,
      queuePaused,
      queuePlanTotal,
      reorderQueue,
      resumeQueue,
      setQueuePlanTotal,
      state.phase,
      state.summary?.progressPercent,
    ],
  );

  return { renderQueueDisplay };
}

export type QueueDisplayScope = ReturnType<typeof useQueueDisplay>;
