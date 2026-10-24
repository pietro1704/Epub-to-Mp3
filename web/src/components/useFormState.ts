import { useEffect, useRef, useState } from 'react';
import { useI18n, useTranslations } from '../i18n/I18nProvider';
import { EngineOption, FootnoteMode, type TtsSelection } from '../types/conversion';
import {
  loadTtsPreferences,
  saveTtsPreferences,
  effectiveTtsPreferences,
  faber,
  edge,
} from '../services/TtsPreferences';
import {
  installBrowserModel,
  installedBrowserVoices,
  browserVoiceId,
} from '../services/BrowserConversionClient';
import { VoiceInfo, QueuedFileEntry, getEngineMeta } from './conversion_form_choices';

export function useFormState() {
  const t = useTranslations();

  const { locale } = useI18n();

  const [preferences, setPreferences] = useState(loadTtsPreferences);
  const selectedModel = useRef(preferences.primary.model_id ?? browserVoiceId);

  const [usePreferences, setUsePreferences] = useState(true);

  const [useSecondary, setUseSecondary] = useState(false);

  const [modelStatus, setModelStatus] = useState<'idle' | 'installing' | 'installed' | 'error'>(
    'idle',
  );

  const [modelError, setModelError] = useState('');

  const labels = t.form.ttsPreferences;

  const updatePreferences = (next: typeof preferences) => {
    saveTtsPreferences({ ...next, policy_version: 2 });
    setPreferences({ ...next, policy_version: 2 });
  };

  const unavailableVoiceLabel = labels.unavailable;

  const initialEngine: EngineOption = preferences.primary.engine;

  const initialMeta = getEngineMeta(initialEngine);

  const [fileQueue, setFileQueue] = useState<QueuedFileEntry[]>([]);

  const [fileError, setFileError] = useState<string | null>(null);

  const [isDragOver, setIsDragOver] = useState(false);

  const dragCounter = useRef(0);

  const [engine, setEngine] = useState<EngineOption>(initialEngine);

  const [voice, setVoice] = useState(initialMeta.defaultVoice);

  const [catalogSelection, setCatalogSelection] = useState<TtsSelection | null>(null);
  const manualSelection =
    catalogSelection ??
    (engine === 'piper' ? { ...faber } : { ...edge, voice: voice || edge.voice });

  const manualSecondary = effectiveTtsPreferences(preferences, manualSelection, true).secondary;

  const effectiveModelId =
    (usePreferences ? preferences.primary : manualSelection).model_id ?? browserVoiceId;
  const installModel = async () => {
    const modelId = selectedModel.current;
    setModelStatus('installing');
    try {
      await installBrowserModel(modelId);
      if (selectedModel.current === modelId) setModelStatus('installed');
    } catch (error) {
      if (selectedModel.current === modelId) {
        setModelError(String(error));
        setModelStatus('error');
      }
    }
  };

  useEffect(() => {
    let active = true;
    const modelId = effectiveModelId;
    selectedModel.current = modelId;
    void installedBrowserVoices()
      .then((voices) => {
        if (active) setModelStatus(voices.includes(modelId) ? 'installed' : 'idle');
      })
      .catch(() => undefined);
    return () => {
      active = false;
    };
  }, [effectiveModelId]);

  const [model, setModel] = useState('');

  const [chapters, setChapters] = useState('');

  const [fromChapterToEnd, setFromChapterToEnd] = useState('');

  const [fromChapterToChapter, setFromChapterToChapter] = useState('');

  const [sections, setSections] = useState('');

  const [priority, setPriority] = useState('');

  const [footnoteMode, setFootnoteMode] = useState<FootnoteMode>('inline');

  const [language, setLanguage] = useState<string>(
    initialMeta.autoLanguage ? 'auto' : (initialMeta.languages[0] ?? ''),
  );

  const [formattingCues, setFormattingCues] = useState(false);

  const [enableCharacterVoices, setEnableCharacterVoices] = useState(false);

  const [narratorVoice, setNarratorVoice] = useState('');

  const [characterVoice, setCharacterVoice] = useState('');

  const [exportToIphone, setExportToIphone] = useState(false);

  const [noParallel, setNoParallel] = useState(false);

  const [multiEngineParallel, setMultiEngineParallel] = useState(false);

  const [maxPerformance, setMaxPerformance] = useState(true);

  const [parallelSlots, setParallelSlots] = useState('');

  const [chapterStallSeconds, setChapterStallSeconds] = useState('');

  const [edgeNetworkTier, setEdgeNetworkTier] = useState<'' | 'slow' | 'medium' | 'fast' | 'ultra'>(
    '',
  );

  const [edgeChunkChars, setEdgeChunkChars] = useState('');

  const [edgeMaxSegmentSeconds, setEdgeMaxSegmentSeconds] = useState('');

  const [edgeEnableParallel, setEdgeEnableParallel] = useState(true);

  const [edgeAutoTune, setEdgeAutoTune] = useState(true);

  const [edgeStableMode, setEdgeStableMode] = useState(false);

  const [engineChainFallback, setEngineChainFallback] = useState(false);

  const [piperMaxProcs, setPiperMaxProcs] = useState('');

  const [bitrate, setBitrate] = useState('');

  const [sampleRate, setSampleRate] = useState('');

  const [channels, setChannels] = useState('');

  const [clearCache, setClearCache] = useState(false);

  const [forceReprocess, setForceReprocess] = useState(false);

  const [filterChapters, setFilterChapters] = useState(false);

  const [verbose, setVerbose] = useState(true);

  const [useLanguageDetection, setUseLanguageDetection] = useState(true);

  const [prioritizePrimaryLanguage, setPrioritizePrimaryLanguage] = useState(true);

  const [healthCheckIntervalSeconds, setHealthCheckIntervalSeconds] = useState('');

  const [healthCheckSlowEdgeCps, setHealthCheckSlowEdgeCps] = useState('');

  const [healthCheckSlowCps, setHealthCheckSlowCps] = useState('');

  const [healthCheckHighCpu, setHealthCheckHighCpu] = useState('');

  const [healthCheckHighMem, setHealthCheckHighMem] = useState('');

  const [healthCheckOkCpu, setHealthCheckOkCpu] = useState('');

  const [healthCheckOkMem, setHealthCheckOkMem] = useState('');

  const [healthCheckSlowStreak, setHealthCheckSlowStreak] = useState('');

  const [showMissingFileError, setShowMissingFileError] = useState(false);

  const [voiceCatalog, setVoiceCatalog] = useState<Record<string, VoiceInfo[]> | null>(null);

  const [voiceLoading, setVoiceLoading] = useState(false);

  const [voiceLoadFailed, setVoiceLoadFailed] = useState(false);

  const [estimatedDuration, setEstimatedDuration] = useState<string | null>(null);

  const [engineEstimates, setEngineEstimates] = useState<Record<
    string,
    {
      estimated_duration_formatted: string;
      estimated_output_mb: number;
      chars_per_second: number;
    }
  > | null>(null);

  const uploadAttemptRef = useRef(0);

  const fileQueueRef = useRef<QueuedFileEntry[]>([]);

  const setFileQueueSafe = (
    updater: QueuedFileEntry[] | ((prev: QueuedFileEntry[]) => QueuedFileEntry[]),
  ) => {
    setFileQueue((prev) => {
      const next =
        typeof updater === 'function'
          ? (updater as (value: QueuedFileEntry[]) => QueuedFileEntry[])(prev)
          : updater;
      fileQueueRef.current = next;
      return next;
    });
  };

  const [draggingId, setDraggingId] = useState<string | null>(null);

  const [dragOverInfo, setDragOverInfo] = useState<{
    id: string;
    position: 'before' | 'after';
  } | null>(null);

  const folderInputRef = useRef<HTMLInputElement>(null);

  const uploadPromisesRef = useRef<Record<string, Promise<void> | undefined>>({});

  const [pendingUploads, setPendingUploads] = useState(0);

  return {
    setVoiceLoading,
    setVoiceLoadFailed,
    setVoiceCatalog,
    fileQueue,
    setEstimatedDuration,
    setEngineEstimates,
    engine,
    voiceCatalog,
    voice,
    pendingUploads,
    setUsePreferences,
    setEngine,
    setVoice,
    setLanguage,
    language,
    setFormattingCues,
    setNoParallel,
    folderInputRef,
    fileQueueRef,
    uploadPromisesRef,
    uploadAttemptRef,
    setPendingUploads,
    setFileQueueSafe,
    setFileError,
    t,
    setShowMissingFileError,
    setDraggingId,
    setDragOverInfo,
    draggingId,
    dragOverInfo,
    preferences,
    usePreferences,
    manualSelection,
    setCatalogSelection,
    useSecondary,
    model,
    chapters,
    sections,
    fromChapterToEnd,
    fromChapterToChapter,
    priority,
    footnoteMode,
    formattingCues,
    enableCharacterVoices,
    narratorVoice,
    characterVoice,
    exportToIphone,
    noParallel,
    multiEngineParallel,
    maxPerformance,
    parallelSlots,
    chapterStallSeconds,
    edgeNetworkTier,
    edgeChunkChars,
    edgeMaxSegmentSeconds,
    edgeEnableParallel,
    edgeAutoTune,
    edgeStableMode,
    engineChainFallback,
    piperMaxProcs,
    bitrate,
    sampleRate,
    channels,
    clearCache,
    forceReprocess,
    filterChapters,
    verbose,
    useLanguageDetection,
    prioritizePrimaryLanguage,
    healthCheckIntervalSeconds,
    healthCheckSlowEdgeCps,
    healthCheckSlowCps,
    healthCheckHighCpu,
    healthCheckHighMem,
    healthCheckOkCpu,
    healthCheckOkMem,
    healthCheckSlowStreak,
    locale,
    isDragOver,
    dragCounter,
    setIsDragOver,
    fileError,
    labels,
    updatePreferences,
    unavailableVoiceLabel,
    installModel,
    modelStatus,
    modelError,
    manualSecondary,
    setUseSecondary,
    voiceLoading,
    voiceLoadFailed,
    setEnableCharacterVoices,
    setNarratorVoice,
    setCharacterVoice,
    setExportToIphone,
    setMultiEngineParallel,
    setMaxPerformance,
    setParallelSlots,
    setChapterStallSeconds,
    setEdgeNetworkTier,
    setModel,
    setEdgeChunkChars,
    setEdgeMaxSegmentSeconds,
    setEdgeEnableParallel,
    setEdgeAutoTune,
    setEdgeStableMode,
    setEngineChainFallback,
    setPiperMaxProcs,
    setBitrate,
    setSampleRate,
    setChannels,
    setVerbose,
    setClearCache,
    setForceReprocess,
    setFilterChapters,
    setUseLanguageDetection,
    setPrioritizePrimaryLanguage,
    setHealthCheckIntervalSeconds,
    setHealthCheckSlowEdgeCps,
    setHealthCheckSlowCps,
    setHealthCheckHighCpu,
    setHealthCheckHighMem,
    setHealthCheckOkCpu,
    setHealthCheckOkMem,
    setHealthCheckSlowStreak,
    setChapters,
    setFromChapterToEnd,
    setFromChapterToChapter,
    setSections,
    setPriority,
    setFootnoteMode,
    showMissingFileError,
    estimatedDuration,
    engineEstimates,
  };
}

export type FormStateScope = ReturnType<typeof useFormState>;
