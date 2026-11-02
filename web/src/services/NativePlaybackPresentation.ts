import { useSyncExternalStore } from 'react';

export type NativePlaybackPhase =
  'idle' | 'starting' | 'playing' | 'paused' | 'completed' | 'failed';
export type NativePlaybackContext = Readonly<{
  owner: symbol;
  jobId: string;
  chapterIndex: number;
}>;
type ActivePhase = Exclude<NativePlaybackPhase, 'idle'>;
type NativePlaybackSnapshot = NativePlaybackContext &
  Readonly<{ phase: ActivePhase; voice: string }>;
let publication: { lease: symbol; snapshot: NativePlaybackSnapshot } | null = null;
const listeners = new Set<() => void>();
const notify = () => listeners.forEach((listener) => listener());
const read = () => publication?.snapshot ?? null;
const readServer = () => null;
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
};

// One installed engine serves the process. Publication is presentation only;
// it never changes conversion state, downloads or persisted MP3 artifacts.
export function createNativePlaybackPublication(context: NativePlaybackContext) {
  const lease = Symbol('native-playback-publication');
  let started = false;
  let closed = false;
  return {
    start() {
      if (closed || started) return;
      started = true;
      publication = { lease, snapshot: { ...context, phase: 'starting', voice: '' } };
      notify();
    },
    update(changes: { phase?: ActivePhase; voice?: string }) {
      if (closed || publication?.lease !== lease) return;
      const previous = publication.snapshot;
      const phase = changes.phase ?? previous.phase;
      const voice = changes.voice ?? previous.voice;
      if (phase === previous.phase && voice === previous.voice) return;
      publication = { lease, snapshot: { ...previous, phase, voice } };
      notify();
    },
    release() {
      closed = true;
      if (publication?.lease !== lease) return;
      publication = null;
      notify();
    },
  };
}
export type NativePlaybackPublication = ReturnType<typeof createNativePlaybackPublication>;

export function useNativePlayback(jobId?: string): NativePlaybackSnapshot | null {
  const snapshot = useSyncExternalStore(subscribe, read, readServer);
  return snapshot?.jobId === jobId ? snapshot : null;
}
