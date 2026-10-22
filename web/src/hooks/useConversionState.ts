import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from 'react';
import { conversionClient, ConversionClient } from '../services/ConversionService';
import { conversionCache } from '../services/ConversionCache';
import { ConversionFormValues, ConversionState, RecentJobEntry } from '../types/conversion';
import { useTranslations } from '../i18n/I18nProvider';
import { useSystemStats } from './useSystemStats';
import { initialState, reducer, createStatusEntryFactory } from './conversion_state';
import {
  AdaptiveTolerances,
  DEFAULT_TOLERANCES,
  resolveRecentSpeed,
  deriveAdaptiveTolerances,
} from './conversion_eta';
import { RESTART_GRACE_MS } from './conversion_runtime_health';

type ConversionStateInput = { client?: ConversionClient };

export function useConversionState({ client }: ConversionStateInput) {
  const [state, dispatch] = useReducer(reducer, initialState);
  const stateRef = useRef(state);
  const api = useMemo(() => client ?? conversionClient, [client]);
  const abortRef = useRef<AbortController | null>(null);
  const seenEventsRef = useRef<Set<string>>(new Set());
  const entryFactoryRef = useRef(createStatusEntryFactory());
  const startTimeRef = useRef<number | null>(null);
  const fileNameRef = useRef<string>('');
  const jobQueueRef = useRef<ConversionFormValues[]>([]);
  const queueActiveRef = useRef(false);
  const queueGenerationRef = useRef(0);
  const processedCountRef = useRef(0);
  const skipModeRef = useRef(false);
  const t = useTranslations();
  const [cachedJobs, setCachedJobs] = useState<
    Array<{
      jobId: string;
      fileName: string;
      timestamp: number;
      engine?: string;
      voice?: string;
      language?: string;
      pendingQueueCount?: number;
    }>
  >([]);
  const [cachedJobsLoading, setCachedJobsLoading] = useState(true);
  const [recentJobs, setRecentJobs] = useState<RecentJobEntry[]>([]);
  const [savedBatch, setSavedBatch] = useState<ConversionFormValues[] | null>(
    () => conversionCache.loadPendingBatch() as ConversionFormValues[] | null,
  );
  const [apiAvailable, setApiAvailable] = useState(true);
  const [healthStatus, setHealthStatus] = useState<'unknown' | 'ok' | 'fail' | 'restarting'>(
    'unknown',
  );
  const systemStats = useSystemStats(client || api.mode === 'embedded' ? 0 : 5000);
  const recentSpeed = useMemo(
    () => resolveRecentSpeed(state.summary),
    [state.summary?.chapterProgress],
  );
  const adaptiveTolerances = useMemo(
    () => deriveAdaptiveTolerances(systemStats.data, recentSpeed, state.engine),
    [systemStats.data, recentSpeed, state.engine],
  );
  const [queuePaused, setQueuePausedState] = useState(false);
  const queuePausedRef = useRef(queuePaused);
  const setQueuePaused = useCallback((value: boolean) => {
    queuePausedRef.current = value;
    setQueuePausedState(value);
  }, []);
  const adaptiveTolerancesRef = useRef<AdaptiveTolerances>(DEFAULT_TOLERANCES);
  const restartGraceRef = useRef<number | null>(null);
  const lastSnapshotAtRef = useRef<number | null>(null);
  const healthFailureCountRef = useRef(0);
  const pollFailureCountRef = useRef(0);
  const streamStatusRef = useRef<'connecting' | 'healthy' | 'fallback' | null>(null);
  const fallbackPollAbortRef = useRef<AbortController | null>(null);
  const isRestartGraceActive = useCallback(() => {
    const until = restartGraceRef.current;
    return typeof until === 'number' && Date.now() < until;
  }, []);
  const beginRestartGrace = useCallback(() => {
    restartGraceRef.current = Date.now() + RESTART_GRACE_MS;
    setApiAvailable(false);
    setHealthStatus('restarting');
  }, []);
  const [queueSnapshot, setQueueSnapshot] = useState<ConversionFormValues[]>([]);
  const syncQueueSnapshot = useCallback(() => {
    setQueueSnapshot([...jobQueueRef.current]);
  }, []);
  const getQueueSnapshotForCache = () => {
    if (jobQueueRef.current.length === 0) {
      return undefined;
    }
    return jobQueueRef.current.map((entry) => {
      const { file: _file, ...rest } = entry;
      return {
        ...rest,
        file: null,
      };
    });
  };

  useEffect(() => {
    adaptiveTolerancesRef.current = adaptiveTolerances;
    healthFailureCountRef.current = Math.min(
      healthFailureCountRef.current,
      adaptiveTolerances.healthFailureLimit,
    );
    pollFailureCountRef.current = Math.min(
      pollFailureCountRef.current,
      adaptiveTolerances.pollFailureLimit,
    );
  }, [adaptiveTolerances]);

  const saveStateWithQueue = (jobId: string, fileName: string, baseState: ConversionState) => {
    if (!jobId) {
      return;
    }
    const pendingBatchQueue = getQueueSnapshotForCache();
    const cacheState: ConversionState = pendingBatchQueue
      ? { ...baseState, pendingBatchQueue }
      : { ...baseState, pendingBatchQueue: undefined };
    conversionCache.save(jobId, fileName, cacheState);
  };

  useEffect(() => {
    stateRef.current = state;
  }, [state]);

  useEffect(() => {
    if (state.phase === 'polling' && state.jobId && fileNameRef.current) {
      saveStateWithQueue(state.jobId, fileNameRef.current, state);
    }
  }, [state]);

  return {
    stateRef,
    saveStateWithQueue,
    fileNameRef,
    streamStatusRef,
    fallbackPollAbortRef,
    restartGraceRef,
    healthFailureCountRef,
    pollFailureCountRef,
    setApiAvailable,
    setHealthStatus,
    isRestartGraceActive,
    adaptiveTolerancesRef,
    state,
    lastSnapshotAtRef,
    api,
    seenEventsRef,
    dispatch,
    entryFactoryRef,
    setCachedJobs,
    apiAvailable,
    startTimeRef,
    setCachedJobsLoading,
    setRecentJobs,
    abortRef,
    t,
    queueActiveRef,
    queueGenerationRef,
    queuePausedRef,
    jobQueueRef,
    syncQueueSnapshot,
    processedCountRef,
    skipModeRef,
    setQueuePaused,
    setSavedBatch,
    beginRestartGrace,
    cachedJobs,
    cachedJobsLoading,
    recentJobs,
    healthStatus,
    queueSnapshot,
    queuePaused,
    savedBatch,
  };
}

export type ConversionStateScope = ReturnType<typeof useConversionState>;
