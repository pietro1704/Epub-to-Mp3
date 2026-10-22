import { useEffect } from 'react';
import { invoke, isTauri, listenTauri } from './lib/tauri';
import { resolveApiUrl } from './config';
import { reportUiIssue } from './services/uiIssueMonitor';
import type { ApplicationStateScope } from './useApplicationState';

type NativeStartupInput = Pick<
  ApplicationStateScope,
  | 'setTauriStarting'
  | 'setTauriEngineError'
  | 'handleTauriStartupReadyRef'
  | 'setTauriStartupLog'
  | 'tauriStarting'
>;

export function useNativeStartup({
  setTauriStarting,
  setTauriEngineError,
  handleTauriStartupReadyRef,
  setTauriStartupLog,
  tauriStarting,
}: NativeStartupInput) {
  // Listen for Tauri sidecar startup events (no-op in browser).
  useEffect(() => {
    if (!isTauri()) return;
    const cleanups: Array<() => void> = [];
    (async () => {
      cleanups.push(
        await listenTauri('tauri-server-restarting', () => {
          // Sidecar crashed and is being auto-restarted — show startup panel.
          setTauriStarting(true);
          setTauriEngineError(null);
        }),
      );
      cleanups.push(
        await listenTauri('tauri-startup-error', (payload) => {
          setTauriStarting(false);
          setTauriEngineError(
            typeof payload === 'string' ? payload : 'Failed to start conversion engine',
          );
        }),
      );
      cleanups.push(
        await listenTauri('tauri-startup-timeout', () => {
          setTauriStarting(false);
          setTauriEngineError(
            'Engine took too long to start. Check Server Logs or restart the app.',
          );
        }),
      );
      cleanups.push(
        await listenTauri('tauri-startup-ready', () => {
          handleTauriStartupReadyRef.current();
        }),
      );
      cleanups.push(
        await listenTauri('tauri-startup-loading', () => {
          setTauriStarting(true);
        }),
      );
      cleanups.push(
        await listenTauri('tauri-server-log', (line) => {
          if (typeof line === 'string') {
            setTauriStartupLog((prev) => {
              const next = [...prev, line];
              return next.length > 200 ? next.slice(-200) : next;
            });
          }
        }),
      );
      // Fetch any logs that were buffered before this listener was registered.
      try {
        const buffered = await invoke<string[]>('get_server_logs');
        if (buffered.length > 0) {
          setTauriStartupLog((prev) => {
            const combined = [...prev, ...buffered];
            return combined.length > 200 ? combined.slice(-200) : combined;
          });
        }
      } catch {
        // Not critical — ignore
      }
    })();
    return () => cleanups.forEach((u) => u());
  }, []);

  // Poll buffered server logs every 2 s while startup is in progress.
  // Also check if the server is already up (handles race where tauri-startup-ready
  // fired before the listener was registered).
  useEffect(() => {
    if (!isTauri() || !tauriStarting) return;
    const id = setInterval(async () => {
      // Fetch buffered logs from Rust
      try {
        const lines = await invoke<string[]>('get_server_logs');
        if (lines.length > 0) {
          setTauriStartupLog(lines.length > 200 ? lines.slice(-200) : lines);
        }
      } catch (e) {
        setTauriStartupLog((prev) => [...prev, `[startup] invoke error: ${String(e)}`]);
      }
      // If server is already responding, mark as ready (race-condition guard)
      try {
        const r = await fetch(resolveApiUrl('/api/health'), {
          signal: AbortSignal.timeout(800),
        });
        if (r.ok) {
          handleTauriStartupReadyRef.current();
        }
      } catch {
        // not up yet
      }
    }, 2000);
    return () => clearInterval(id);
  }, [tauriStarting]);

  useEffect(() => {
    if (typeof window === 'undefined') {
      return;
    }

    const handleError = (event: ErrorEvent) => {
      reportUiIssue('app', 'Unhandled UI error', {
        severity: 'error',
        details: event.message || 'Unknown browser error',
      });
    };

    const handleRejection = (event: PromiseRejectionEvent) => {
      const reason =
        typeof event.reason === 'string'
          ? event.reason
          : event.reason instanceof Error
            ? event.reason.message
            : 'Unknown rejection';
      reportUiIssue('app', 'Unhandled async UI error', {
        severity: 'error',
        details: reason,
      });
    };

    window.addEventListener('error', handleError);
    window.addEventListener('unhandledrejection', handleRejection);
    return () => {
      window.removeEventListener('error', handleError);
      window.removeEventListener('unhandledrejection', handleRejection);
    };
  }, []);
}

export type NativeStartupScope = ReturnType<typeof useNativeStartup>;
