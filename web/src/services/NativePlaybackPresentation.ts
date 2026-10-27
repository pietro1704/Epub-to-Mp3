import { useSyncExternalStore } from 'react';

export type NativePlaybackPhase = 'idle' | 'starting' | 'playing' | 'paused' | 'completed' | 'failed';
type NativePlaybackSnapshot = {
  jobId: string;
  chapterIndex: number;
  phase: NativePlaybackPhase;
  voice: string;
};

// One installed speech engine serves the process. This presentation never
// changes conversion state, download completion or persisted MP3 artifacts.
let snapshot: NativePlaybackSnapshot | null = null;
const listeners = new Set<() => void>();
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => { listeners.delete(listener); };
};
const read = () => snapshot;
export function publishNativePlayback(value: NativePlaybackSnapshot | null): void {
  snapshot = value;
  listeners.forEach(listener => listener());
}
export function useNativePlayback(jobId?: string): NativePlaybackSnapshot | null {
  const value = useSyncExternalStore(subscribe, read, () => null);
  return value?.jobId === jobId ? value : null;
}
