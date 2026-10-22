import { useEffect, useMemo } from 'react';
import { EngineOption } from '../types/conversion';
import { MAX_UPLOAD_MB, resolveApiUrl } from '../config';
import { conversionClient } from '../services/ConversionService';
import {
  VoiceInfo,
  DEFAULT_VOICE_SUGGESTIONS,
  EngineInsights,
  getEngineMeta,
} from './conversion_form_choices';

import type { FormStateScope } from './useFormState';
import type { ConversionFormProps } from './conversion_form_contract';

type FormNarrationPolicyInput = Pick<
  FormStateScope,
  | 'setVoiceLoading'
  | 'setVoiceLoadFailed'
  | 'setVoiceCatalog'
  | 'fileQueue'
  | 'setEstimatedDuration'
  | 'setEngineEstimates'
  | 'engine'
  | 'voiceCatalog'
  | 'voice'
  | 'pendingUploads'
  | 'setUsePreferences'
  | 'setEngine'
  | 'setVoice'
  | 'setLanguage'
  | 'language'
  | 'setFormattingCues'
  | 'setNoParallel'
> &
  Pick<ConversionFormProps, 'isSubmitting' | 'currentJob'>;

export function useFormNarrationPolicy({
  setVoiceLoading,
  setVoiceLoadFailed,
  setVoiceCatalog,
  fileQueue,
  setEstimatedDuration,
  setEngineEstimates,
  engine,
  voiceCatalog,
  voice,
  isSubmitting,
  pendingUploads,
  setUsePreferences,
  setEngine,
  setVoice,
  setLanguage,
  language,
  currentJob,
  setFormattingCues,
  setNoParallel,
}: FormNarrationPolicyInput) {
  useEffect(() => {
    if (conversionClient.mode === 'embedded') return;
    let isMounted = true;

    const fetchVoices = async () => {
      setVoiceLoading(true);
      setVoiceLoadFailed(false);
      try {
        const response = await fetch(resolveApiUrl('/api/voices'));
        if (!response.ok) {
          throw new Error(`Failed to load voices: ${response.status}`);
        }
        const payload = await response.json();
        const voiceEntries = payload?.voices as
          Record<string, Array<Record<string, unknown>>> | undefined;
        if (!voiceEntries || !isMounted) {
          return;
        }
        const normalized: Record<string, VoiceInfo[]> = {};
        Object.entries(voiceEntries).forEach(([engineKey, entries]) => {
          normalized[engineKey] = (entries || [])
            .map((entry) => {
              const id = String(entry?.id ?? entry?.name ?? '');
              return {
                name: id,
                label: typeof entry?.label === 'string' ? entry.label : id,
                multilingual: Boolean(entry?.multilingual),
              };
            })
            .filter((entry) => !!entry.name);
        });
        if (Object.keys(normalized).length > 0) {
          setVoiceCatalog(normalized);
        }
      } catch {
        if (isMounted) {
          setVoiceLoadFailed(true);
        }
      } finally {
        if (isMounted) {
          setVoiceLoading(false);
        }
      }
    };

    fetchVoices();

    return () => {
      isMounted = false;
    };
  }, []);

  // Browser-local conversion has no remote estimate endpoint.
  useEffect(() => {
    if (conversionClient.mode === 'embedded') return;
    const readyEntry = fileQueue.find((e) => e.status === 'ready' && e.uploadId);
    if (!readyEntry?.uploadId) {
      setEstimatedDuration(null);
      setEngineEstimates(null);
      return;
    }
    let cancelled = false;
    const url = resolveApiUrl(
      `/api/estimate?upload_id=${encodeURIComponent(readyEntry.uploadId)}&engine=${encodeURIComponent(engine)}`,
    );
    fetch(url)
      .then((r) => (r.ok ? r.json() : null))
      .then(
        (
          data: {
            estimated_duration_formatted?: string;
            engine_estimates?: Record<
              string,
              {
                estimated_duration_formatted: string;
                estimated_output_mb: number;
                chars_per_second: number;
              }
            >;
          } | null,
        ) => {
          if (!cancelled && data?.estimated_duration_formatted) {
            setEstimatedDuration(data.estimated_duration_formatted);
            setEngineEstimates(data.engine_estimates ?? null);
          }
        },
      )
      .catch(() => {
        // Estimate is best-effort; ignore errors
      });
    return () => {
      cancelled = true;
    };
  }, [fileQueue, engine]);

  const engineMeta = useMemo<EngineInsights>(() => getEngineMeta(engine), [engine]);

  const languageOptionsList = useMemo(() => {
    const entries = Array.isArray(engineMeta.languages) ? engineMeta.languages.filter(Boolean) : [];
    const seen = new Set<string>();
    const normalized: string[] = [];
    entries.forEach((code) => {
      if (!seen.has(code)) {
        seen.add(code);
        normalized.push(code);
      }
    });
    if (engineMeta.autoLanguage && !seen.has('auto')) {
      normalized.unshift('auto');
    }
    if (normalized.length === 0) {
      return engineMeta.autoLanguage ? ['auto'] : [];
    }
    return normalized;
  }, [engineMeta]);

  const maxUploadMbDisplay = Math.round(MAX_UPLOAD_MB);

  const voiceSource = voiceCatalog ?? DEFAULT_VOICE_SUGGESTIONS;

  const voiceSuggestions = useMemo(() => {
    const voices: VoiceInfo[] = [];
    const seenNames = new Set<string>();

    if (engineMeta.defaultVoice && !seenNames.has(engineMeta.defaultVoice)) {
      const defaultInfo = (voiceSource[engine] ?? []).find(
        (v) => v.name === engineMeta.defaultVoice,
      );
      voices.push(
        defaultInfo ?? {
          name: engineMeta.defaultVoice,
          multilingual: false,
          label: engineMeta.defaultVoice,
        },
      );
      seenNames.add(engineMeta.defaultVoice);
    }

    (voiceSource[engine] ?? []).forEach((voiceInfo) => {
      if (!seenNames.has(voiceInfo.name)) {
        voices.push(voiceInfo);
        seenNames.add(voiceInfo.name);
      }
    });

    return voices;
  }, [engine, engineMeta.defaultVoice, voiceCatalog]);

  const currentVoiceMultilingual = useMemo(() => {
    return voiceSuggestions.find((v) => v.name === voice)?.multilingual ?? false;
  }, [voiceSuggestions, voice]);

  const disableSubmit = isSubmitting || pendingUploads > 0;

  const END_DROP_ID = '__queue_end__';

  const parseOptionalInt = (value: string): number | undefined => {
    const trimmed = value.trim();
    if (!trimmed) {
      return undefined;
    }
    const parsed = Number.parseInt(trimmed, 10);
    return Number.isNaN(parsed) ? undefined : parsed;
  };

  const parseOptionalNumber = (value: string): number | undefined => {
    const trimmed = value.trim();
    if (!trimmed) {
      return undefined;
    }
    const parsed = Number.parseFloat(trimmed);
    return Number.isNaN(parsed) ? undefined : parsed;
  };

  const handleEngineChange = (nextEngine: EngineOption) => {
    setUsePreferences(false);
    setEngine(nextEngine);
    const meta = getEngineMeta(nextEngine);
    // In auto mode, don't set a voice (will be selected automatically)
    if (nextEngine === 'auto') {
      setVoice('');
      setLanguage('auto');
    } else {
      setVoice(meta.defaultVoice);
      setLanguage(meta.autoLanguage ? 'auto' : (meta.languages[0] ?? ''));
    }
  };

  useEffect(() => {
    if (languageOptionsList.length === 0) {
      return;
    }
    if (!languageOptionsList.includes(language)) {
      setLanguage(languageOptionsList[0] ?? '');
    }
  }, [languageOptionsList, language]);

  useEffect(() => {
    if (typeof currentJob?.formattingCues === 'boolean') {
      setFormattingCues(currentJob.formattingCues);
    }
  }, [currentJob?.formattingCues]);

  useEffect(() => {
    if (typeof currentJob?.noParallel === 'boolean') {
      setNoParallel(currentJob.noParallel);
    }
  }, [currentJob?.noParallel]);

  return {
    maxUploadMbDisplay,
    parseOptionalInt,
    parseOptionalNumber,
    END_DROP_ID,
    handleEngineChange,
    languageOptionsList,
    engineMeta,
    voiceSuggestions,
    currentVoiceMultilingual,
    disableSubmit,
  };
}

export type FormNarrationPolicyScope = ReturnType<typeof useFormNarrationPolicy>;
