import { DragEvent, FormEvent, useEffect, useMemo, useRef, useState } from 'react';
import { useI18n, useTranslations } from '../i18n/I18nProvider';
import { ConversionFormValues, ConversionState, EngineOption, FootnoteMode, SubmitBatchOptions } from '../types/conversion';
import { API_BASE_URL, MAX_UPLOAD_BYTES, MAX_UPLOAD_MB } from '../config';
import type { UploadResponse } from '../services/ConversionService';

interface ConversionFormProps {
  isSubmitting: boolean;
  onSubmit: (values: ConversionFormValues, options?: SubmitBatchOptions) => Promise<void> | void;
  onUploadFile: (file: File) => Promise<UploadResponse>;
  currentJob?: {
    jobId?: string;
    phase: ConversionState['phase'];
    bookTitle?: string | null;
    engine?: string;
    voice?: string;
    language?: string;
    formattingCues?: boolean;
  };
}

interface VoiceInfo {
  name: string;
  multilingual: boolean;
  label?: string;
}

const DEFAULT_VOICE_SUGGESTIONS: Record<string, VoiceInfo[]> = {
  edge: [
    { name: 'pt-BR-ThalitaMultilingualNeural', multilingual: true, label: 'Thalita – pt-BR (multilingual)' },
    { name: 'pt-BR-FranciscaNeural', multilingual: false },
    { name: 'en-US-JennyNeural', multilingual: false },
    { name: 'es-ES-ElviraNeural', multilingual: false },
  ],
  piper: [
    { name: 'pt_BR-faber-medium.onnx', multilingual: false },
    { name: 'en_US-lessac-medium.onnx', multilingual: false },
  ],
  coqui: [
    { name: 'tts_models/pt/cv/vits', multilingual: false },
    { name: 'tts_models/multilingual/multi-dataset/xtts_v2', multilingual: true },
  ],
  auto: [
    { name: 'tts_models/pt/cv/vits', multilingual: false },
    { name: 'pt-BR-ThalitaMultilingualNeural', multilingual: true },
  ],
};

type KnownEngine = 'edge' | 'piper' | 'coqui' | 'auto';

interface EngineInsights {
  defaultVoice: string;
  multiLingual: boolean;
  autoLanguage: boolean;
  languages: string[];
}

const ENGINE_INFO: Record<KnownEngine, EngineInsights> = {
  edge: {
    defaultVoice: 'pt-BR-ThalitaMultilingualNeural',
    multiLingual: true,
    autoLanguage: true,
    languages: ['auto'],
  },
  piper: {
    defaultVoice: 'pt_BR-faber-medium.onnx',
    multiLingual: false,
    autoLanguage: false,
    languages: ['pt', 'en'],
  },
  coqui: {
    defaultVoice: 'tts_models/pt/cv/vits',
    multiLingual: true,
    autoLanguage: false,
    languages: ['pt', 'en', 'es', 'fr', 'de'],
  },
  auto: {
    defaultVoice: '',
    multiLingual: true,
    autoLanguage: true,
    languages: ['auto'],
  },
};

const FALLBACK_ENGINE_META: EngineInsights = {
  defaultVoice: '',
  multiLingual: true,
  autoLanguage: true,
  languages: ['auto'],
};

interface QueuedFileEntry {
  id: string;
  file: File;
  name: string;
  size: number;
  uploadId?: string;
  status: 'uploading' | 'ready' | 'error';
  error?: string;
  attemptId?: number;
}

function getEngineMeta(engine: EngineOption): EngineInsights {
  if ((ENGINE_INFO as Record<string, EngineInsights>)[engine]) {
    return (ENGINE_INFO as Record<string, EngineInsights>)[engine];
  }
  return FALLBACK_ENGINE_META;
}

export default function ConversionForm({ isSubmitting, onSubmit, onUploadFile, currentJob }: ConversionFormProps): JSX.Element {
  const t = useTranslations();
  const { locale } = useI18n();
  const initialEngine: EngineOption = 'auto';
  const initialMeta = getEngineMeta(initialEngine);
  const [fileQueue, setFileQueue] = useState<QueuedFileEntry[]>([]);
  const [fileError, setFileError] = useState<string | null>(null);
  const [engine, setEngine] = useState<EngineOption>(initialEngine);
  const [voice, setVoice] = useState(initialMeta.defaultVoice);
  const [chapters, setChapters] = useState('');
  const [priority, setPriority] = useState('');
  const [footnoteMode, setFootnoteMode] = useState<FootnoteMode>('inline');
  const [language, setLanguage] = useState<string>(initialMeta.autoLanguage ? 'auto' : initialMeta.languages[0] ?? '');
  const [formattingCues, setFormattingCues] = useState(true);
  const [showMissingFileError, setShowMissingFileError] = useState(false);
  const [voiceCatalog, setVoiceCatalog] = useState<Record<string, VoiceInfo[]> | null>(null);
  const [voiceLoading, setVoiceLoading] = useState(false);
  const [voiceLoadFailed, setVoiceLoadFailed] = useState(false);
  const uploadAttemptRef = useRef(0);
  const [draggingId, setDraggingId] = useState<string | null>(null);
  const [dragOverInfo, setDragOverInfo] = useState<{ id: string; position: 'before' | 'after' } | null>(null);

  useEffect(() => {
    let isMounted = true;

    const fetchVoices = async () => {
      setVoiceLoading(true);
      setVoiceLoadFailed(false);
      try {
        const base = (API_BASE_URL || '/api').replace(/\/$/, '');
        const response = await fetch(`${base}/voices`);
        if (!response.ok) {
          throw new Error(`Failed to load voices: ${response.status}`);
        }
        const payload = await response.json();
        const voiceEntries = payload?.voices as Record<string, Array<Record<string, unknown>>> | undefined;
        if (!voiceEntries || !isMounted) {
          return;
        }
        const normalized: Record<string, VoiceInfo[]> = {};
        Object.entries(voiceEntries).forEach(([engineKey, entries]) => {
          normalized[engineKey] = (entries || []).map((entry) => {
            const id = String(entry?.id ?? entry?.name ?? '');
            return {
              name: id,
              label: typeof entry?.label === 'string' ? entry.label : id,
              multilingual: Boolean(entry?.multilingual),
            };
          }).filter((entry) => !!entry.name);
        });
        if (Object.keys(normalized).length > 0) {
          setVoiceCatalog(normalized);
        }
      } catch (error) {
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
      const defaultInfo = (voiceSource[engine] ?? []).find((v) => v.name === engineMeta.defaultVoice);
      voices.push(defaultInfo ?? { name: engineMeta.defaultVoice, multilingual: false, label: engineMeta.defaultVoice });
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
    return voiceSuggestions.find(v => v.name === voice)?.multilingual ?? false;
  }, [voiceSuggestions, voice]);

  const uploadsInProgress = useMemo(() => fileQueue.some(entry => entry.status === 'uploading'), [fileQueue]);
  const usableEntries = useMemo(() => fileQueue.filter(entry => entry.status !== 'error'), [fileQueue]);
  const disableSubmit = isSubmitting || uploadsInProgress || usableEntries.length === 0;
  const END_DROP_ID = '__queue_end__';

  const handleDragStart = (event: DragEvent<HTMLLIElement>, entryId: string) => {
    if (fileQueue.length <= 1 || isSubmitting) {
      event.preventDefault();
      return;
    }
    setDraggingId(entryId);
    setDragOverInfo(null);
    if (event.dataTransfer) {
      event.dataTransfer.setData('text/plain', entryId);
      event.dataTransfer.effectAllowed = 'move';
    }
  };

  const handleDragOverItem = (event: DragEvent<HTMLLIElement>, entryId: string) => {
    if (!draggingId || entryId === draggingId) {
      return;
    }
    event.preventDefault();
    const rect = event.currentTarget.getBoundingClientRect();
    const offset = event.clientY - rect.top;
    const position: 'before' | 'after' = offset > rect.height / 2 ? 'after' : 'before';
    setDragOverInfo({ id: entryId, position });
  };

  const handleDropOnItem = (event: DragEvent<HTMLLIElement>, entryId: string) => {
    if (!draggingId) {
      return;
    }
    event.preventDefault();
    const info = dragOverInfo && dragOverInfo.id === entryId ? dragOverInfo : { id: entryId, position: 'before' as const };
    const targetIndex = fileQueue.findIndex((entry) => entry.id === entryId);
    if (targetIndex === -1) {
      return;
    }
    const insertIndex = info.position === 'after' ? targetIndex + 1 : targetIndex;
    moveEntryToIndex(draggingId, insertIndex);
    setDragOverInfo(null);
  };

  const handleDropAtEnd = (event: DragEvent<HTMLElement>) => {
    if (!draggingId) {
      return;
    }
    event.preventDefault();
    moveEntryToIndex(draggingId, fileQueue.length);
    setDragOverInfo(null);
  };

  const handleDragEnd = () => {
    setDraggingId(null);
    setDragOverInfo(null);
  };

  const formatFileSize = (bytes: number): string => {
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(1)} KB`;
    }
    if (bytes < 1024 * 1024 * 1024) {
      return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
    }
    return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GB`;
  };

  const startUploadForEntry = (entryId: string, file: File) => {
    const attemptId = uploadAttemptRef.current + 1;
    uploadAttemptRef.current = attemptId;
    setFileQueue((prev) => prev.map((entry) => (
      entry.id === entryId
        ? { ...entry, status: 'uploading', error: undefined, attemptId }
        : entry
    )));
    (async () => {
      try {
        const response = await onUploadFile(file);
        setFileQueue((prev) => prev.map((entry) => {
          if (entry.id !== entryId || entry.attemptId !== attemptId) {
            return entry;
          }
          return {
            ...entry,
            status: 'ready',
            uploadId: response.uploadId,
            name: response.fileName || entry.name,
            attemptId: undefined,
          };
        }));
      } catch (error) {
        const message = error instanceof Error ? error.message : 'Falha ao enviar arquivo';
        setFileQueue((prev) => prev.map((entry) => {
          if (entry.id !== entryId || entry.attemptId !== attemptId) {
            return entry;
          }
          return {
            ...entry,
            status: 'error',
            error: message,
            attemptId: undefined,
          };
        }));
      }
    })();
  };

  const addFilesToQueue = (files: FileList | File[]) => {
    const additions: QueuedFileEntry[] = [];
    Array.from(files).forEach((file) => {
      if (!file) return;
      if (file.size > MAX_UPLOAD_BYTES) {
        setFileError(`${t.form.errorFileTooLarge(maxUploadMbDisplay)} (${file.name})`);
        return;
      }
      const id = typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function'
        ? crypto.randomUUID()
        : `queued-${Date.now()}-${Math.random().toString(16).slice(2)}`;
      additions.push({
        id,
        file,
        name: file.name,
        size: file.size,
        status: 'uploading',
      });
    });
    if (additions.length === 0) {
      return;
    }
    setFileError(null);
    setShowMissingFileError(false);
    setFileQueue((prev) => [...prev, ...additions]);
    additions.forEach((entry) => startUploadForEntry(entry.id, entry.file));
  };

  const removeFromQueue = (entryId: string) => {
    setFileQueue((prev) => prev.filter((entry) => entry.id !== entryId));
  };

  const moveEntry = (entryId: string, delta: number) => {
    setFileQueue((prev) => {
      const index = prev.findIndex((entry) => entry.id === entryId);
      if (index === -1) {
        return prev;
      }
      const targetIndex = index + delta;
      if (targetIndex < 0 || targetIndex >= prev.length) {
        return prev;
      }
      const next = [...prev];
      const [item] = next.splice(index, 1);
      next.splice(targetIndex, 0, item);
      return next;
    });
  };

  const moveEntryToIndex = (entryId: string, targetIndex: number) => {
    setFileQueue((prev) => {
      const currentIndex = prev.findIndex((entry) => entry.id === entryId);
      if (currentIndex === -1) {
        return prev;
      }
      const constrained = Math.max(0, Math.min(prev.length, targetIndex));
      if (constrained === currentIndex || constrained === currentIndex + 1) {
        return prev;
      }
      const next = [...prev];
      const [item] = next.splice(currentIndex, 1);
      const insertIndex = constrained > currentIndex ? constrained - 1 : constrained;
      next.splice(insertIndex, 0, item);
      return next;
    });
  };

  const handleSubmit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (usableEntries.length === 0) {
      setShowMissingFileError(true);
      return;
    }
    if (uploadsInProgress) {
      return;
    }

    setShowMissingFileError(false);
    const sharedConfig = {
      engine,
      voice: voice || undefined,
      chapters: chapters || undefined,
      priority: priority || undefined,
      footnoteMode,
      language: engineMeta.autoLanguage || !language || language === 'auto' ? undefined : language,
      formattingCues,
      uiLanguage: locale,
    };
    const payloads = usableEntries.map((entry) => ({
      ...sharedConfig,
      file: entry.uploadId ? null : entry.file,
      fileName: entry.file?.name ?? entry.name,
      uploadId: entry.uploadId,
    }));
    const [first, ...rest] = payloads;
    await onSubmit(first, { batchQueue: rest });
    setFileQueue([]);
  };

  const translateLanguage = (code: string): string => {
    return t.form.languageOptions[code] ?? code.toUpperCase();
  };

  const handleEngineChange = (nextEngine: EngineOption) => {
    setEngine(nextEngine);
    const meta = getEngineMeta(nextEngine);
    setVoice(meta.defaultVoice);
    setLanguage(meta.autoLanguage ? 'auto' : meta.languages[0] ?? '');
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

  const handleUseSample = async () => {
    try {
      const basePath = import.meta.env.BASE_URL || '/';
      const normalizedBase = basePath.endsWith('/') ? basePath : `${basePath}/`;
      const response = await fetch(`${normalizedBase}sample.epub`);
      const blob = await response.blob();
      const file = new File([blob], 'sample.epub', { type: 'application/epub+zip' });
      setShowMissingFileError(false);
      setFileError(null);
      addFilesToQueue([file]);
    } catch (error) {
      console.error('Failed to load sample book:', error);
    }
  };

  return (
    <form className="conversion-form" onSubmit={handleSubmit}>
      <fieldset className="form-field">
        <label htmlFor="file">{t.form.fileLabel}</label>
        <div className="file-input-row">
          <input
            id="file"
            name="file"
            type="file"
            accept="application/epub+zip,application/pdf"
            multiple
            disabled={isSubmitting}
            onChange={(event) => {
              const files = event.target.files;
              if (files && files.length > 0) {
                addFilesToQueue(files);
                event.target.value = '';
              }
            }}
            className="file-input-row__input"
          />
          <button
            type="button"
            onClick={handleUseSample}
            disabled={isSubmitting}
            className="button-secondary file-input-row__sample"
          >
            {t.form.useSampleButton}
          </button>
        </div>
        {fileError && (
          <p role="alert" className="form-error">
            {fileError}
          </p>
        )}
        <div className="file-queue">
          <div className="file-queue__header">
            <span className="file-queue__title">{t.form.fileQueueLabel}</span>
            {fileQueue.length > 0 && (
              <span className="file-queue__count">{t.form.fileQueueCount(fileQueue.length)}</span>
            )}
          </div>
          {fileQueue.length === 0 ? (
            <p className="form-hint">
              {currentJob && currentJob.bookTitle
                ? t.form.fileQueueWithCurrent(currentJob.bookTitle)
                : t.form.fileQueueEmpty}
            </p>
          ) : (
            <>
              <ul
                className="file-queue__list"
                onDragOver={(event) => {
                  if (!draggingId || event.target !== event.currentTarget) return;
                  event.preventDefault();
                  setDragOverInfo({ id: END_DROP_ID, position: 'after' });
                }}
                onDrop={(event) => {
                  if (event.target === event.currentTarget) {
                    handleDropAtEnd(event);
                  }
                }}
              >
                {fileQueue.map((entry, index) => {
                  const canMoveUp = index > 0;
                  const canMoveDown = index < fileQueue.length - 1;
                  const isDragging = entry.id === draggingId;
                  const dropBefore = dragOverInfo?.id === entry.id && dragOverInfo.position === 'before';
                  const dropAfter = dragOverInfo?.id === entry.id && dragOverInfo.position === 'after';
                  const itemClasses = [
                    'file-queue__item',
                    isDragging ? 'file-queue__item--dragging' : '',
                    dropBefore ? 'file-queue__item--drop-before' : '',
                    dropAfter ? 'file-queue__item--drop-after' : '',
                  ].filter(Boolean).join(' ');
                  return (
                    <li
                      key={entry.id}
                      className={itemClasses}
                      draggable={fileQueue.length > 1 && !isSubmitting}
                      onDragStart={(event) => handleDragStart(event, entry.id)}
                      onDragOver={(event) => handleDragOverItem(event, entry.id)}
                      onDrop={(event) => handleDropOnItem(event, entry.id)}
                      onDragEnd={handleDragEnd}
                    >
                      <div className="file-queue__meta">
                        <span className="file-queue__name" title={entry.name}>
                          {index + 1}. {entry.name}
                        </span>
                        <span className="file-queue__details">
                          {formatFileSize(entry.size)} •{' '}
                          {entry.status === 'ready' && (
                            <span>✅ {t.form.autoUploadReady}</span>
                          )}
                          {entry.status === 'uploading' && (
                            <span>📤 {t.form.uploadingFile}</span>
                          )}
                          {entry.status === 'error' && (
                            <span>⚠️ {entry.error}</span>
                          )}
                        </span>
                      </div>
                      <div className="file-queue__actions">
                        <button
                          type="button"
                          className="file-queue__swap"
                          onClick={() => moveEntry(entry.id, -1)}
                          disabled={!canMoveUp || isSubmitting}
                          aria-label={t.form.fileQueueMoveUp}
                          title={t.form.fileQueueMoveUp}
                        >
                          ↑
                        </button>
                        <button
                          type="button"
                          className="file-queue__swap"
                          onClick={() => moveEntry(entry.id, 1)}
                          disabled={!canMoveDown || isSubmitting}
                          aria-label={t.form.fileQueueMoveDown}
                          title={t.form.fileQueueMoveDown}
                        >
                          ↓
                        </button>
                        <button
                          type="button"
                          className="file-queue__remove"
                          onClick={() => removeFromQueue(entry.id)}
                          disabled={isSubmitting}
                        >
                          {t.form.fileQueueRemove}
                        </button>
                      </div>
                    </li>
                  );
                })}
              </ul>
              {fileQueue.length > 1 && (
                <>
                  <div
                    className={`file-queue__dropzone ${dragOverInfo?.id === END_DROP_ID ? 'file-queue__dropzone--active' : ''}`}
                    onDragOver={(event) => {
                      if (!draggingId) return;
                      event.preventDefault();
                      setDragOverInfo({ id: END_DROP_ID, position: 'after' });
                    }}
                    onDrop={handleDropAtEnd}
                    onDragLeave={() => {
                      if (dragOverInfo?.id === END_DROP_ID) {
                        setDragOverInfo(null);
                      }
                    }}
                  >
                    {t.form.fileQueueReorderHint}
                  </div>
                </>
              )}
            </>
          )}
        </div>
        <p className="form-hint">{t.form.autoUploadHint}</p>
        <p className="form-hint">{t.form.fileHint}</p>
      </fieldset>

      <details className="form-advanced">
        <summary>{t.form.advancedSummary}</summary>
        <div className="form-advanced__content">
          <fieldset className="form-row">
            <label htmlFor="engine">{t.form.engineLabel}</label>
            <select
              id="engine"
              name="engine"
              value={engine}
              disabled={isSubmitting}
              onChange={(event) => handleEngineChange(event.target.value as EngineOption)}
            >
              {t.form.engineOptions.map((option) => (
                <option key={option.value} value={option.value}>
                  {option.label}
                </option>
              ))}
            </select>
            <p className="form-hint">{t.form.engineOptions.find((option) => option.value === engine)?.help}</p>
            <div className="engine-insight">
              <div className="engine-insight__item">
                <span className="engine-insight__label">{t.form.defaultVoiceLabel}</span>
                <code className="engine-insight__value">{engineMeta.defaultVoice}</code>
              </div>
              <div className="engine-insight__item">
                <span className="engine-insight__label">{t.form.multilingualSupportLabel}</span>
                <span className="engine-insight__value">
                  {engineMeta.multiLingual ? t.form.multilingualYes : t.form.multilingualNo}
                </span>
              </div>
              <div className="engine-insight__item">
                <span className="engine-insight__label">{engineMeta.autoLanguage ? t.form.autoLanguageLabel : t.form.manualLanguageLabel}</span>
              </div>
              {!engineMeta.autoLanguage && engineMeta.languages.length > 0 && (
                <div className="engine-insight__languages">
                  <span className="engine-insight__label">{t.form.availableLanguagesLabel}:</span>
                  <ul>
                    {engineMeta.languages.map((code) => (
                      <li key={code}>{translateLanguage(code)}</li>
                    ))}
                  </ul>
                </div>
              )}
            </div>
          </fieldset>

          <fieldset className="form-row">
            <label htmlFor="language">{t.form.languageLabel}</label>
            <select
              id="language"
              name="language"
              value={language}
              disabled={isSubmitting || languageOptionsList.length === 0}
              onChange={(event) => setLanguage(event.target.value)}
            >
              {languageOptionsList.map((code) => (
                <option key={code} value={code}>
                  {translateLanguage(code)}
                </option>
              ))}
            </select>
            <p className="form-hint">
              {engineMeta.autoLanguage ? t.form.languageNotRequired : t.form.languageHint}
            </p>
          </fieldset>

          <fieldset className="form-row">
            <label htmlFor="voice">{t.form.voiceLabel}</label>
            <select
              id="voice"
              name="voice"
              value={voice}
              disabled={isSubmitting}
              onChange={(event) => setVoice(event.target.value)}
            >
              {voiceSuggestions.map((voiceInfo) => {
                const label = voiceInfo.label && voiceInfo.label !== voiceInfo.name
                  ? `${voiceInfo.label} • ${voiceInfo.name}`
                  : voiceInfo.label ?? voiceInfo.name;
                return (
                  <option key={voiceInfo.name} value={voiceInfo.name}>
                    {label} {voiceInfo.multilingual ? '🌐' : ''}
                  </option>
                );
              })}
            </select>
            <p className="form-hint">
              {currentVoiceMultilingual && '🌐 '}
              {t.form.voiceHint}
              {currentVoiceMultilingual && ` ${t.form.voiceMultilingualHint}`}
            </p>
            {voiceLoading && <p className="form-hint">{t.form.voiceLoading}</p>}
            {voiceLoadFailed && (
              <p className="form-hint form-hint--warning">{t.form.voiceLoadFailed}</p>
            )}
          </fieldset>

          <fieldset className="form-row">
            <label htmlFor="formattingCuesToggle">{t.form.formattingCuesLabel}</label>
            <label className="form-toggle" htmlFor="formattingCuesToggle">
              <input
                id="formattingCuesToggle"
                type="checkbox"
                checked={formattingCues}
                disabled={isSubmitting}
                onChange={(event) => setFormattingCues(event.target.checked)}
              />
              <span>{formattingCues ? t.form.formattingCuesOn : t.form.formattingCuesOff}</span>
            </label>
            <p className="form-hint">{t.form.formattingCuesDescription}</p>
          </fieldset>

          <fieldset className="form-row">
            <label htmlFor="chapters">{t.form.chaptersLabel}</label>
            <input
              id="chapters"
              name="chapters"
              placeholder={t.form.chaptersPlaceholder}
              value={chapters}
              disabled={isSubmitting}
              onChange={(event) => setChapters(event.target.value)}
            />
            <p className="form-hint">{t.form.chaptersHint}</p>
          </fieldset>

          <fieldset className="form-row">
            <label htmlFor="priority">{t.form.priorityLabel}</label>
            <input
              id="priority"
              name="priority"
              placeholder={t.form.priorityPlaceholder}
              value={priority}
              disabled={isSubmitting}
              onChange={(event) => setPriority(event.target.value)}
            />
            <p className="form-hint">{t.form.priorityHint}</p>
          </fieldset>

          <fieldset className="form-field">
            <legend className="form-legend">{t.form.footnoteLegend}</legend>
            <div className="segmented-list">
              {t.form.footnoteOptions.map((option) => {
                const inputId = `footnote-${option.value}`;
                return (
                  <label key={option.value} className="segmented-list__item" htmlFor={inputId}>
                    <input
                      type="radio"
                      id={inputId}
                      name="footnoteMode"
                      value={option.value}
                      checked={footnoteMode === option.value}
                      disabled={isSubmitting}
                      onChange={() => setFootnoteMode(option.value)}
                    />
                    <span className="segmented-list__content">
                      <span className="segmented-list__title">{option.title}</span>
                      <span className="segmented-list__description">{option.description}</span>
                    </span>
                  </label>
                );
              })}
            </div>
          </fieldset>
        </div>
      </details>

      {showMissingFileError && (
        <p role="alert" className="form-error">
          {t.form.errorNoFile}
        </p>
      )}

      <button
        type="submit"
        disabled={disableSubmit}
        className="form-submit"
      >
        {isSubmitting
          ? t.form.submitBusy
          : t.form.submitIdle}
      </button>
    </form>
  );
}
