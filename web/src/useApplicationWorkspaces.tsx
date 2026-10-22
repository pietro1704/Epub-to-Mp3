import type { AppProps } from './application_contract';
export type { AppProps } from './application_contract';
import { useApplicationState } from './useApplicationState';
import { useNativeStartup } from './useNativeStartup';
import { useWorkspaceIntents } from './useWorkspaceIntents';
import { usePlaybackWorkspace } from './usePlaybackWorkspace';
import { useApplicationNotifications } from './useApplicationNotifications';
import { useQueueDisplay } from './useQueueDisplay';
import { useCompletedConversionEffects } from './useCompletedConversionEffects';
import { useBackendRestartDialog } from './useBackendRestartDialog';
import { useWorkspaceTabs } from './useWorkspaceTabs';
import { useLibraryWorkspace } from './useLibraryWorkspace';

export function useApplicationWorkspaces(props?: AppProps) {
  const state = useApplicationState({ props });
  useNativeStartup(state);
  const intents = useWorkspaceIntents(state);
  const playback = usePlaybackWorkspace({ ...state, ...intents });
  const notifications = useApplicationNotifications({ ...state, ...intents, ...playback });
  const queue = useQueueDisplay({ ...state, ...intents, ...playback, ...notifications });
  useCompletedConversionEffects({ ...state, ...intents, ...playback, ...notifications, ...queue });
  const restart = useBackendRestartDialog({
    ...state,
    ...intents,
    ...playback,
    ...notifications,
    ...queue,
  });
  const tabs = useWorkspaceTabs({
    ...state,
    ...intents,
    ...playback,
    ...notifications,
    ...queue,
    ...restart,
  });
  const library = useLibraryWorkspace({
    ...state,
    ...intents,
    ...playback,
    ...notifications,
    ...queue,
    ...restart,
    ...tabs,
  });
  return {
    ...state,
    ...intents,
    ...playback,
    ...notifications,
    ...queue,
    ...restart,
    ...tabs,
    ...library,
  };
}

export type AppScope = ReturnType<typeof useApplicationWorkspaces>;
