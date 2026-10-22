import { useCallback } from 'react';
import type { RecentJobEntry } from './types/conversion';
import type { ApplicationStateScope } from './useApplicationState';
import type { WorkspaceIntentsScope } from './useWorkspaceIntents';

type LibraryWorkspaceInput = Pick<
  ApplicationStateScope,
  | 'setActiveTab'
  | 'resume'
  | 'manualDownloadOverrideRef'
  | 'setViewingRecentJob'
  | 'setUserSelectedTab'
  | 'setHiddenResumableIds'
  | 'removeCachedJob'
> &
  Pick<WorkspaceIntentsScope, 'clearRecentJobView'>;

export function useLibraryWorkspace({
  setActiveTab,
  clearRecentJobView,
  resume,
  manualDownloadOverrideRef,
  setViewingRecentJob,
  setUserSelectedTab,
  setHiddenResumableIds,
  removeCachedJob,
}: LibraryWorkspaceInput) {
  const handleResumeJob = useCallback(
    (jobId: string) => {
      console.log('[App] Resuming job:', jobId);
      setActiveTab('progress');
      clearRecentJobView();
      resume(jobId);
    },
    [clearRecentJobView, resume],
  );

  const handleViewRecentJobOutputs = useCallback(
    (job: RecentJobEntry) => {
      manualDownloadOverrideRef.current = true;
      if (job.outputs && job.outputs.length > 0) {
        setViewingRecentJob(job);
      } else {
        clearRecentJobView();
      }
      setActiveTab('downloads');
      setUserSelectedTab(true);
    },
    [clearRecentJobView, setActiveTab, setUserSelectedTab, setViewingRecentJob],
  );

  const handleRemoveResumableJob = useCallback(
    (jobId: string) => {
      setHiddenResumableIds((prev) => {
        const next = new Set(prev);
        next.add(jobId);
        return next;
      });
      removeCachedJob(jobId);
    },
    [removeCachedJob],
  );

  return { handleResumeJob, handleRemoveResumableJob, handleViewRecentJobOutputs };
}

export type LibraryWorkspaceScope = ReturnType<typeof useLibraryWorkspace>;
