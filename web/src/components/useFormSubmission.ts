import { FormEvent } from 'react';
import { ConversionTemplate } from '../types/conversion';
import { effectiveTtsPreferences } from '../services/TtsPreferences';
import type { FormStateScope } from './useFormState';
import type { FormNarrationPolicyScope } from './useFormNarrationPolicy';
import type { FormUploadSessionScope } from './useFormUploadSession';
import type { ConversionFormProps } from './conversion_form_contract';

type FormSubmissionInput = Pick<
  FormStateScope,
  | 'fileQueueRef'
  | 'setShowMissingFileError'
  | 'uploadPromisesRef'
  | 'preferences'
  | 'usePreferences'
  | 'manualSelection'
  | 'useSecondary'
  | 'voice'
  | 'model'
  | 'chapters'
  | 'sections'
  | 'fromChapterToEnd'
  | 'fromChapterToChapter'
  | 'priority'
  | 'footnoteMode'
  | 'language'
  | 'formattingCues'
  | 'enableCharacterVoices'
  | 'narratorVoice'
  | 'characterVoice'
  | 'exportToIphone'
  | 'noParallel'
  | 'multiEngineParallel'
  | 'maxPerformance'
  | 'parallelSlots'
  | 'chapterStallSeconds'
  | 'edgeNetworkTier'
  | 'edgeChunkChars'
  | 'edgeMaxSegmentSeconds'
  | 'edgeEnableParallel'
  | 'edgeAutoTune'
  | 'edgeStableMode'
  | 'engineChainFallback'
  | 'piperMaxProcs'
  | 'bitrate'
  | 'sampleRate'
  | 'channels'
  | 'clearCache'
  | 'forceReprocess'
  | 'filterChapters'
  | 'verbose'
  | 'useLanguageDetection'
  | 'prioritizePrimaryLanguage'
  | 'healthCheckIntervalSeconds'
  | 'healthCheckSlowEdgeCps'
  | 'healthCheckSlowCps'
  | 'healthCheckHighCpu'
  | 'healthCheckHighMem'
  | 'healthCheckOkCpu'
  | 'healthCheckOkMem'
  | 'healthCheckSlowStreak'
  | 'locale'
  | 'setFileQueueSafe'
  | 't'
  | 'setFileError'
> &
  Pick<FormNarrationPolicyScope, 'parseOptionalInt' | 'parseOptionalNumber'> &
  Pick<FormUploadSessionScope, 'addFilesToQueue'> &
  Pick<ConversionFormProps, 'onSubmitIntent' | 'onSubmit'>;

export function useFormSubmission({
  fileQueueRef,
  setShowMissingFileError,
  onSubmitIntent,
  uploadPromisesRef,
  preferences,
  usePreferences,
  manualSelection,
  useSecondary,
  voice,
  model,
  chapters,
  sections,
  fromChapterToEnd,
  fromChapterToChapter,
  priority,
  footnoteMode,
  language,
  formattingCues,
  enableCharacterVoices,
  narratorVoice,
  characterVoice,
  exportToIphone,
  noParallel,
  multiEngineParallel,
  maxPerformance,
  parseOptionalInt,
  parallelSlots,
  parseOptionalNumber,
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
  onSubmit,
  setFileQueueSafe,
  t,
  setFileError,
  addFilesToQueue,
}: FormSubmissionInput) {
  const handleSubmit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const initialEntries = fileQueueRef.current.filter((entry) => entry.status !== 'error');
    if (initialEntries.length === 0) {
      setShowMissingFileError(true);
      return;
    }
    setShowMissingFileError(false);
    onSubmitIntent?.();
    const pendingUploads = Object.values(uploadPromisesRef.current).filter(
      (promise): promise is Promise<void> => Boolean(promise),
    );
    if (pendingUploads.length > 0) {
      await Promise.allSettled(pendingUploads);
    }
    const normalizeEdgeTier = (value: string): 'slow' | 'medium' | 'fast' | 'ultra' | undefined => {
      if (value === 'slow' || value === 'medium' || value === 'fast' || value === 'ultra') {
        return value;
      }
      return undefined;
    };

    const effectivePreferences = effectiveTtsPreferences(
      preferences,
      usePreferences ? null : manualSelection,
      useSecondary,
    );
    const sharedConfig: ConversionTemplate = {
      engine: effectivePreferences.primary.engine,
      tts_preferences: structuredClone(effectivePreferences),
      voice: voice || undefined,
      model: model || undefined,
      chapters: chapters || undefined,
      sections: sections || undefined,
      fromChapterToEnd: fromChapterToEnd || undefined,
      fromChapterToChapter: fromChapterToChapter || undefined,
      priority: priority || undefined,
      footnoteMode,
      language: !language || language === 'auto' ? undefined : language,
      formattingCues,
      enableCharacterVoices,
      narratorVoice: narratorVoice || undefined,
      characterVoice: characterVoice || undefined,
      exportToIphone,
      noParallel,
      multiEngineParallel,
      maxPerformance,
      parallelSlots: parseOptionalInt(parallelSlots),
      chapterStallSeconds: parseOptionalNumber(chapterStallSeconds),
      edgeNetworkTier: normalizeEdgeTier(edgeNetworkTier),
      edgeChunkChars: parseOptionalInt(edgeChunkChars),
      edgeMaxSegmentSeconds: parseOptionalInt(edgeMaxSegmentSeconds),
      edgeEnableParallel,
      edgeAutoTune,
      edgeStableMode,
      engineChainFallback,
      piperMaxProcs: parseOptionalInt(piperMaxProcs),
      bitrate: bitrate || undefined,
      sampleRate: parseOptionalInt(sampleRate),
      channels: parseOptionalInt(channels),
      clearCache,
      forceReprocess,
      filterChapters,
      verbose,
      useLanguageDetection,
      prioritizePrimaryLanguage,
      healthCheckIntervalSeconds: parseOptionalNumber(healthCheckIntervalSeconds),
      healthCheckSlowEdgeCps: parseOptionalNumber(healthCheckSlowEdgeCps),
      healthCheckSlowCps: parseOptionalNumber(healthCheckSlowCps),
      healthCheckHighCpu: parseOptionalNumber(healthCheckHighCpu),
      healthCheckHighMem: parseOptionalNumber(healthCheckHighMem),
      healthCheckOkCpu: parseOptionalNumber(healthCheckOkCpu),
      healthCheckOkMem: parseOptionalNumber(healthCheckOkMem),
      healthCheckSlowStreak: parseOptionalInt(healthCheckSlowStreak),
      uiLanguage: locale,
    };
    const readyEntries = fileQueueRef.current.filter((entry) => entry.status === 'ready');
    if (readyEntries.length === 0) {
      setShowMissingFileError(true);
      return;
    }
    const payloads = readyEntries.map((entry) => {
      const hasUpload = Boolean(entry.uploadId && entry.uploadId.trim().length > 0);
      return {
        ...sharedConfig,
        file: hasUpload ? null : entry.file,
        fileName: entry.file?.name ?? entry.name,
        uploadId: entry.uploadId,
        bookTitle: entry.bookTitle,
        bookAuthor: entry.bookAuthor,
        coverUrl: entry.coverUrl,
        localPath: entry.localPath,
      };
    });
    const [first, ...rest] = payloads;
    await onSubmit(first, { batchQueue: rest });
    setFileQueueSafe([]);
  };

  const translateLanguage = (code: string): string => {
    return t.form.languageOptions[code] ?? code.toUpperCase();
  };

  const handleUseSample = async () => {
    try {
      const basePath = import.meta.env.BASE_URL || '/';
      const normalizedBase = basePath.endsWith('/') ? basePath : `${basePath}/`;
      const response = await fetch(`${normalizedBase}sample.epub`);
      const blob = await response.blob();
      const file = new File([blob], 'sample.epub', {
        type: 'application/epub+zip',
      });
      setShowMissingFileError(false);
      setFileError(null);
      addFilesToQueue([file]);
    } catch (error) {
      console.error('Failed to load sample book:', error);
    }
  };

  return { handleSubmit, handleUseSample, translateLanguage };
}

export type FormSubmissionScope = ReturnType<typeof useFormSubmission>;
