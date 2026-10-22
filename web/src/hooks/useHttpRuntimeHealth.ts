import { useEffect } from 'react';
import { ConversionClient } from '../services/ConversionService';
import { estimateEtaSeconds } from './conversion_eta';
import { resolveHealthEndpoint, isNetworkError } from './conversion_runtime_health';
import type { ConversionStateScope } from './useConversionState';
import type { ConversionSnapshotsScope } from './useConversionSnapshots';

type HttpRuntimeHealthInput = Pick<
  ConversionStateScope,
  | 'api'
  | 'setApiAvailable'
  | 'state'
  | 'adaptiveTolerancesRef'
  | 'lastSnapshotAtRef'
  | 'healthFailureCountRef'
  | 'streamStatusRef'
  | 'fallbackPollAbortRef'
  | 'pollFailureCountRef'
  | 'startTimeRef'
  | 'dispatch'
> &
  Pick<
    ConversionSnapshotsScope,
    'markApiOnline' | 'markApiOffline' | 'appendSnapshotEvents' | 'applySnapshotMeta'
  > & { client?: ConversionClient };

export function useHttpRuntimeHealth({
  client,
  api,
  setApiAvailable,
  state,
  adaptiveTolerancesRef,
  lastSnapshotAtRef,
  markApiOnline,
  healthFailureCountRef,
  markApiOffline,
  streamStatusRef,
  fallbackPollAbortRef,
  pollFailureCountRef,
  appendSnapshotEvents,
  startTimeRef,
  applySnapshotMeta,
  dispatch,
}: HttpRuntimeHealthInput) {
  useEffect(() => {
    if (client || api.mode === 'embedded') {
      setApiAvailable(true);
      return undefined;
    }
    let cancelled = false;
    let isFirstCheck = true;
    let timeoutId: number | undefined;
    const endpoint = resolveHealthEndpoint();
    const visibleIntervalMs = 30000;
    const hiddenIntervalMs = 60000;
    const isActivePhase = state.phase === 'polling' || state.phase === 'submitting';

    const canMarkOffline = () => {
      const graceMs = adaptiveTolerancesRef.current.activeSnapshotGraceMs;
      if (!isActivePhase) {
        return true;
      }
      const lastSnapshotAt = lastSnapshotAtRef.current;
      if (!lastSnapshotAt) {
        return true;
      }
      return Date.now() - lastSnapshotAt > graceMs;
    };

    const scheduleNext = (delay: number) => {
      if (cancelled) {
        return;
      }
      timeoutId = window.setTimeout(() => check(false), delay);
    };

    const check = async (retryOnFail = false) => {
      if (cancelled) {
        return;
      }
      if (typeof document !== 'undefined' && document.visibilityState === 'hidden') {
        scheduleNext(hiddenIntervalMs);
        return;
      }
      const controller = new AbortController();
      // Longer timeout on first check to avoid false negatives on page load
      const tolerances = adaptiveTolerancesRef.current;
      const timeoutMs = isFirstCheck
        ? tolerances.healthCheckFirstTimeoutMs
        : tolerances.healthCheckTimeoutMs;
      const timeout = setTimeout(() => controller.abort(), timeoutMs);
      let ok = false;
      try {
        const response = await fetch(endpoint, {
          method: 'GET',
          cache: 'no-store',
          signal: controller.signal,
        });
        if (!cancelled) {
          if (response.ok) {
            markApiOnline();
            ok = true;
            isFirstCheck = false;
          } else {
            healthFailureCountRef.current += 1;
            if (
              healthFailureCountRef.current >= tolerances.healthFailureLimit &&
              canMarkOffline()
            ) {
              markApiOffline();
            }
          }
        }
      } catch {
        if (!cancelled) {
          healthFailureCountRef.current += 1;
          if (healthFailureCountRef.current >= tolerances.healthFailureLimit && canMarkOffline()) {
            markApiOffline();
          }
        }
      } finally {
        clearTimeout(timeout);
      }
      if (isFirstCheck && retryOnFail && !ok) {
        scheduleNext(1000);
        return;
      }
      isFirstCheck = false;
      scheduleNext(visibleIntervalMs);
    };

    check(true); // First check with retry enabled
    return () => {
      cancelled = true;
      if (timeoutId) {
        window.clearTimeout(timeoutId);
      }
    };
  }, [api, client, markApiOffline, markApiOnline, state.phase]);

  useEffect(() => {
    if (typeof window === 'undefined') {
      return () => {};
    }
    if (state.phase !== 'polling') {
      return () => {};
    }
    if (!state.jobId) {
      return () => {};
    }
    if (!api.fetch) {
      return () => {};
    }
    const jobId = state.jobId;
    let cancelled = false;
    let timeoutId: number | undefined;
    const intervalMs = 2000;
    const staleThresholdMs = 4000;
    let requestController: AbortController | null = null;

    const tick = async () => {
      if (cancelled) {
        return;
      }
      if (streamStatusRef.current === 'connecting' || streamStatusRef.current === 'healthy') {
        timeoutId = window.setTimeout(tick, intervalMs);
        return;
      }
      const lastSnapshotAt = lastSnapshotAtRef.current;
      if (lastSnapshotAt && Date.now() - lastSnapshotAt < staleThresholdMs) {
        timeoutId = window.setTimeout(tick, intervalMs);
        return;
      }
      try {
        requestController = new AbortController();
        fallbackPollAbortRef.current = requestController;
        const snapshot = await api.fetch(jobId, requestController.signal);
        if (cancelled) {
          return;
        }
        lastSnapshotAtRef.current = Date.now();
        pollFailureCountRef.current = 0;
        appendSnapshotEvents(snapshot.events);
        const etaSeconds = estimateEtaSeconds(snapshot, startTimeRef.current);
        applySnapshotMeta(snapshot, etaSeconds);
        markApiOnline();
      } catch (error) {
        if (!cancelled && isNetworkError(error)) {
          pollFailureCountRef.current += 1;
          const tolerances = adaptiveTolerancesRef.current;
          const lastSnapshotAt = lastSnapshotAtRef.current;
          const hasRecentSnapshot =
            typeof lastSnapshotAt === 'number' &&
            Date.now() - lastSnapshotAt < tolerances.activeSnapshotGraceMs;
          if (pollFailureCountRef.current >= tolerances.pollFailureLimit && !hasRecentSnapshot) {
            markApiOffline();
          }
        }
      } finally {
        if (fallbackPollAbortRef.current === requestController) {
          fallbackPollAbortRef.current = null;
        }
        requestController = null;
        if (!cancelled) {
          timeoutId = window.setTimeout(tick, intervalMs);
        }
      }
    };

    timeoutId = window.setTimeout(tick, intervalMs);
    return () => {
      cancelled = true;
      requestController?.abort();
      if (fallbackPollAbortRef.current) {
        fallbackPollAbortRef.current.abort();
        fallbackPollAbortRef.current = null;
      }
      if (timeoutId) {
        window.clearTimeout(timeoutId);
      }
    };
  }, [
    api,
    applySnapshotMeta,
    appendSnapshotEvents,
    markApiOffline,
    markApiOnline,
    state.jobId,
    state.phase,
  ]);

  useEffect(() => {
    if (typeof window === 'undefined') {
      return () => {};
    }
    if (state.phase !== 'polling') {
      return () => {};
    }
    if (typeof state.etaSeconds !== 'number' || state.etaSeconds <= 1) {
      return () => {};
    }
    const currentEta = state.etaSeconds;

    const timeoutId = window.setTimeout(() => {
      dispatch({
        type: 'update-meta',
        etaSeconds: Math.max(0, Math.ceil(currentEta) - 1),
      });
    }, 1000);

    return () => {
      window.clearTimeout(timeoutId);
    };
  }, [state.etaSeconds, state.phase]);

  return {};
}

export type HttpRuntimeHealthScope = ReturnType<typeof useHttpRuntimeHealth>;
