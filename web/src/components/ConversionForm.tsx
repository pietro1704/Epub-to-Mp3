import {
  DragEvent,
  FormEvent,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { useI18n, useTranslations } from "../i18n/I18nProvider";
import {
  ConversionFormValues,
  ConversionState,
  ConversionTemplate,
  EngineOption,
  FootnoteMode,
  SubmitBatchOptions,
} from "../types/conversion";
import { MAX_UPLOAD_BYTES, MAX_UPLOAD_MB, resolveApiUrl } from "../config";
import type { UploadResponse } from "../services/ConversionService";

interface ConversionFormProps {
  isSubmitting: boolean;
  onSubmit: (
    values: ConversionFormValues,
    options?: SubmitBatchOptions,
  ) => Promise<void> | void;
  onUploadFile: (file: File) => Promise<UploadResponse>;
  onSubmitIntent?: () => void;
  onUploadStateChange?: (pendingUploads: number) => void;
  currentJob?: {
    jobId?: string;
    phase: ConversionState["phase"];
    bookTitle?: string | null;
    engine?: string;
    voice?: string;
    language?: string;
    formattingCues?: boolean;
    noParallel?: boolean;
  };
}

interface VoiceInfo {
  name: string;
  multilingual: boolean;
  label?: string;
}

const DEFAULT_VOICE_SUGGESTIONS: Record<string, VoiceInfo[]> = {
  edge: [
    {
      name: "pt-BR-ThalitaMultilingualNeural",
      multilingual: true,
      label: "Thalita – pt-BR (multilingual)",
    },
    { name: "pt-BR-FranciscaNeural", multilingual: false },
    { name: "en-US-JennyNeural", multilingual: false },
    { name: "es-ES-ElviraNeural", multilingual: false },
  ],
  piper: [
    { name: "pt_BR-faber-medium.onnx", multilingual: false },
    { name: "en_US-lessac-medium.onnx", multilingual: false },
  ],
  coqui: [
    {
      name: "tts_models/multilingual/multi-dataset/xtts_v2",
      multilingual: true,
    },
    { name: "tts_models/pt/cv/vits", multilingual: false },
  ],
  kokoro: [
    {
      name: "af_heart",
      multilingual: false,
      label: "Heart – American English Female",
    },
    {
      name: "af_bella",
      multilingual: false,
      label: "Bella – American English Female",
    },
    {
      name: "bf_emma",
      multilingual: false,
      label: "Emma – British English Female",
    },
    { name: "jf_alpha", multilingual: false, label: "Alpha – Japanese Female" },
    {
      name: "zf_xiaobei",
      multilingual: false,
      label: "Xiaobei – Chinese Female",
    },
  ],
  spark: [
    { name: "default", multilingual: true, label: "Default – Spark Voice" },
    {
      name: "clone",
      multilingual: true,
      label: "Clone – Custom Voice (reference audio)",
    },
  ],
};

type KnownEngine = "edge" | "piper" | "coqui" | "kokoro" | "spark";

interface EngineInsights {
  defaultVoice: string;
  multiLingual: boolean;
  autoLanguage: boolean;
  languages: string[];
}

const ENGINE_INFO: Record<KnownEngine, EngineInsights> = {
  edge: {
    defaultVoice: "pt-BR-ThalitaMultilingualNeural",
    multiLingual: true,
    autoLanguage: true,
    languages: ["auto"],
  },
  piper: {
    defaultVoice: "pt_BR-faber-medium.onnx",
    multiLingual: false,
    autoLanguage: false,
    languages: ["pt", "en"],
  },
  coqui: {
    defaultVoice: "tts_models/multilingual/multi-dataset/xtts_v2",
    multiLingual: true,
    autoLanguage: false,
    languages: ["pt", "en", "es", "fr", "de"],
  },
  kokoro: {
    defaultVoice: "af_heart",
    multiLingual: true,
    autoLanguage: false,
    languages: ["en", "ja", "zh"],
  },
  spark: {
    defaultVoice: "default",
    multiLingual: true,
    autoLanguage: true,
    languages: ["auto"],
  },
};

const FALLBACK_ENGINE_META: EngineInsights = {
  defaultVoice: "",
  multiLingual: true,
  autoLanguage: true,
  languages: ["auto"],
};

interface QueuedFileEntry {
  id: string;
  file: File;
  name: string;
  size: number;
  uploadId?: string;
  status: "uploading" | "ready" | "error";
  error?: string;
  attemptId?: number;
  bookTitle?: string;
  bookAuthor?: string;
  detectedLanguage?: string;
}

const SUPPORTED_BOOK_EXTENSIONS = new Set([".epub", ".pdf"]);

function getEngineMeta(engine: EngineOption): EngineInsights {
  if ((ENGINE_INFO as Record<string, EngineInsights>)[engine]) {
    return (ENGINE_INFO as Record<string, EngineInsights>)[engine];
  }
  return FALLBACK_ENGINE_META;
}

export default function ConversionForm({
  isSubmitting,
  onSubmit,
  onUploadFile,
  onSubmitIntent,
  onUploadStateChange,
  currentJob,
}: ConversionFormProps): JSX.Element {
  const t = useTranslations();
  const { locale } = useI18n();
  const initialEngine: EngineOption = "edge";
  const initialMeta = getEngineMeta(initialEngine);
  const [fileQueue, setFileQueue] = useState<QueuedFileEntry[]>([]);
  const [fileError, setFileError] = useState<string | null>(null);
  const [engine, setEngine] = useState<EngineOption>(initialEngine);
  const [voice, setVoice] = useState(initialMeta.defaultVoice);
  const [model, setModel] = useState("");
  const [chapters, setChapters] = useState("");
  const [fromChapterToEnd, setFromChapterToEnd] = useState("");
  const [fromChapterToChapter, setFromChapterToChapter] = useState("");
  const [sections, setSections] = useState("");
  const [priority, setPriority] = useState("");
  const [footnoteMode, setFootnoteMode] = useState<FootnoteMode>("inline");
  const [language, setLanguage] = useState<string>(
    initialMeta.autoLanguage ? "auto" : (initialMeta.languages[0] ?? ""),
  );
  const [formattingCues, setFormattingCues] = useState(true);
  const [noParallel, setNoParallel] = useState(false);
  const [maxPerformance, setMaxPerformance] = useState(true);
  const [parallelSlots, setParallelSlots] = useState("");
  const [chapterStallSeconds, setChapterStallSeconds] = useState("");
  const [edgeNetworkTier, setEdgeNetworkTier] = useState<
    "" | "slow" | "medium" | "fast" | "ultra"
  >("");
  const [edgeChunkChars, setEdgeChunkChars] = useState("");
  const [edgeMaxSegmentSeconds, setEdgeMaxSegmentSeconds] = useState("");
  const [edgeEnableParallel, setEdgeEnableParallel] = useState(true);
  const [edgeAutoTune, setEdgeAutoTune] = useState(true);
  const [edgeStableMode, setEdgeStableMode] = useState(false);
  const [coquiChunkChars, setCoquiChunkChars] = useState("");
  const [coquiMaxWorkers, setCoquiMaxWorkers] = useState("");
  const [coquiSafeMode, setCoquiSafeMode] = useState(true);
  const [piperMaxProcs, setPiperMaxProcs] = useState("");
  const [bitrate, setBitrate] = useState("8k");
  const [sampleRate, setSampleRate] = useState("16000");
  const [channels, setChannels] = useState("1");
  const [clearCache, setClearCache] = useState(false);
  const [forceReprocess, setForceReprocess] = useState(false);
  const [filterChapters, setFilterChapters] = useState(false);
  const [verbose, setVerbose] = useState(true);
  const [useLanguageDetection, setUseLanguageDetection] = useState(true);
  const [prioritizePrimaryLanguage, setPrioritizePrimaryLanguage] =
    useState(true);
  const [healthCheckIntervalSeconds, setHealthCheckIntervalSeconds] =
    useState("");
  const [healthCheckSlowEdgeCps, setHealthCheckSlowEdgeCps] = useState("");
  const [healthCheckSlowCps, setHealthCheckSlowCps] = useState("");
  const [healthCheckHighCpu, setHealthCheckHighCpu] = useState("");
  const [healthCheckHighMem, setHealthCheckHighMem] = useState("");
  const [healthCheckOkCpu, setHealthCheckOkCpu] = useState("");
  const [healthCheckOkMem, setHealthCheckOkMem] = useState("");
  const [healthCheckSlowStreak, setHealthCheckSlowStreak] = useState("");
  const [showMissingFileError, setShowMissingFileError] = useState(false);
  const [voiceCatalog, setVoiceCatalog] = useState<Record<
    string,
    VoiceInfo[]
  > | null>(null);
  const [voiceLoading, setVoiceLoading] = useState(false);
  const [voiceLoadFailed, setVoiceLoadFailed] = useState(false);
  const [estimatedDuration, setEstimatedDuration] = useState<string | null>(
    null,
  );
  const uploadAttemptRef = useRef(0);
  const fileQueueRef = useRef<QueuedFileEntry[]>([]);
  const setFileQueueSafe = (
    updater:
      | QueuedFileEntry[]
      | ((prev: QueuedFileEntry[]) => QueuedFileEntry[]),
  ) => {
    setFileQueue((prev) => {
      const next =
        typeof updater === "function"
          ? (updater as (value: QueuedFileEntry[]) => QueuedFileEntry[])(prev)
          : updater;
      fileQueueRef.current = next;
      return next;
    });
  };
  const [draggingId, setDraggingId] = useState<string | null>(null);
  const [dragOverInfo, setDragOverInfo] = useState<{
    id: string;
    position: "before" | "after";
  } | null>(null);
  const folderInputRef = useRef<HTMLInputElement>(null);
  const uploadPromisesRef = useRef<Record<string, Promise<void> | undefined>>(
    {},
  );
  const [pendingUploads, setPendingUploads] = useState(0);

  useEffect(() => {
    const input = folderInputRef.current;
    if (!input) {
      return;
    }
    input.setAttribute("webkitdirectory", "");
    input.setAttribute("directory", "");
    input.setAttribute("mozdirectory", "");
  }, []);

  useEffect(() => {
    fileQueueRef.current = fileQueue;
    const pending = fileQueue.filter(
      (entry) => entry.status === "uploading",
    ).length;
    onUploadStateChange?.(pending);
  }, [fileQueue, onUploadStateChange]);

  useEffect(() => {
    let isMounted = true;

    const fetchVoices = async () => {
      setVoiceLoading(true);
      setVoiceLoadFailed(false);
      try {
        const response = await fetch(resolveApiUrl("/api/voices"));
        if (!response.ok) {
          throw new Error(`Failed to load voices: ${response.status}`);
        }
        const payload = await response.json();
        const voiceEntries = payload?.voices as
          | Record<string, Array<Record<string, unknown>>>
          | undefined;
        if (!voiceEntries || !isMounted) {
          return;
        }
        const normalized: Record<string, VoiceInfo[]> = {};
        Object.entries(voiceEntries).forEach(([engineKey, entries]) => {
          normalized[engineKey] = (entries || [])
            .map((entry) => {
              const id = String(entry?.id ?? entry?.name ?? "");
              return {
                name: id,
                label: typeof entry?.label === "string" ? entry.label : id,
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

  // Fetch pre-conversion duration estimate when a file is ready and engine changes
  useEffect(() => {
    const readyEntry = fileQueue.find(
      (e) => e.status === "ready" && e.uploadId,
    );
    if (!readyEntry?.uploadId) {
      setEstimatedDuration(null);
      return;
    }
    let cancelled = false;
    const url = resolveApiUrl(
      `/api/estimate?upload_id=${encodeURIComponent(readyEntry.uploadId)}&engine=${encodeURIComponent(engine)}`,
    );
    fetch(url)
      .then((r) => (r.ok ? r.json() : null))
      .then((data: { estimated_duration_formatted?: string } | null) => {
        if (!cancelled && data?.estimated_duration_formatted) {
          setEstimatedDuration(data.estimated_duration_formatted);
        }
      })
      .catch(() => {
        // Estimate is best-effort; ignore errors
      });
    return () => {
      cancelled = true;
    };
  }, [fileQueue, engine]);

  const engineMeta = useMemo<EngineInsights>(
    () => getEngineMeta(engine),
    [engine],
  );
  const languageOptionsList = useMemo(() => {
    const entries = Array.isArray(engineMeta.languages)
      ? engineMeta.languages.filter(Boolean)
      : [];
    const seen = new Set<string>();
    const normalized: string[] = [];
    entries.forEach((code) => {
      if (!seen.has(code)) {
        seen.add(code);
        normalized.push(code);
      }
    });
    if (engineMeta.autoLanguage && !seen.has("auto")) {
      normalized.unshift("auto");
    }
    if (normalized.length === 0) {
      return engineMeta.autoLanguage ? ["auto"] : [];
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
    return (
      voiceSuggestions.find((v) => v.name === voice)?.multilingual ?? false
    );
  }, [voiceSuggestions, voice]);

  const disableSubmit = isSubmitting || pendingUploads > 0;
  const END_DROP_ID = "__queue_end__";

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

  const handleDragStart = (
    event: DragEvent<HTMLLIElement>,
    entryId: string,
  ) => {
    if (fileQueue.length <= 1 || isSubmitting) {
      event.preventDefault();
      return;
    }
    setDraggingId(entryId);
    setDragOverInfo(null);
    if (event.dataTransfer) {
      event.dataTransfer.setData("text/plain", entryId);
      event.dataTransfer.effectAllowed = "move";
    }
  };

  const handleDragOverItem = (
    event: DragEvent<HTMLLIElement>,
    entryId: string,
  ) => {
    if (!draggingId || entryId === draggingId) {
      return;
    }
    event.preventDefault();
    const rect = event.currentTarget.getBoundingClientRect();
    const offset = event.clientY - rect.top;
    const position: "before" | "after" =
      offset > rect.height / 2 ? "after" : "before";
    setDragOverInfo({ id: entryId, position });
  };

  const handleDropOnItem = (
    event: DragEvent<HTMLLIElement>,
    entryId: string,
  ) => {
    if (!draggingId) {
      return;
    }
    event.preventDefault();
    const info =
      dragOverInfo && dragOverInfo.id === entryId
        ? dragOverInfo
        : { id: entryId, position: "before" as const };
    const targetIndex = fileQueue.findIndex((entry) => entry.id === entryId);
    if (targetIndex === -1) {
      return;
    }
    const insertIndex =
      info.position === "after" ? targetIndex + 1 : targetIndex;
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
    // Evita reenvio se upload já existe ou está em andamento para este item
    if (uploadPromisesRef.current[entryId]) {
      return;
    }
    const existing = fileQueueRef.current.find((entry) => entry.id === entryId);
    if (existing?.uploadId && existing.status === "ready") {
      return;
    }

    const attemptId = uploadAttemptRef.current + 1;
    uploadAttemptRef.current = attemptId;
    setPendingUploads((count) => count + 1);
    setFileQueueSafe((prev) =>
      prev.map((entry) =>
        entry.id === entryId
          ? { ...entry, status: "uploading", error: undefined, attemptId }
          : entry,
      ),
    );
    const uploadPromise = (async () => {
      try {
        const response = await onUploadFile(file);
        setFileQueueSafe((prev) =>
          prev.map((entry) => {
            if (entry.id !== entryId || entry.attemptId !== attemptId) {
              return entry;
            }
            return {
              ...entry,
              status: "ready",
              uploadId: response.uploadId,
              name: response.fileName || entry.name,
              bookTitle: response.bookTitle,
              bookAuthor: response.bookAuthor,
              attemptId: undefined,
            };
          }),
        );
      } catch (error) {
        const message =
          error instanceof Error ? error.message : "File upload failed";
        const unsupported =
          typeof message === "string" &&
          (message.toLowerCase().includes("not supported") ||
            message.toLowerCase().includes("not supported"));
        if (unsupported) {
          setFileQueueSafe((prev) =>
            prev.map((entry) => {
              if (entry.id !== entryId || entry.attemptId !== attemptId) {
                return entry;
              }
              return {
                ...entry,
                status: "ready",
                error: undefined,
                attemptId: undefined,
              };
            }),
          );
          return;
        }
        setFileQueueSafe((prev) =>
          prev.map((entry) => {
            if (entry.id !== entryId || entry.attemptId !== attemptId) {
              return entry;
            }
            return {
              ...entry,
              status: "error",
              error: message,
              attemptId: undefined,
            };
          }),
        );
      }
    })();
    uploadPromisesRef.current[entryId] = uploadPromise;
    uploadPromise
      .finally(() => {
        delete uploadPromisesRef.current[entryId];
        setPendingUploads((count) => Math.max(0, count - 1));
        onUploadStateChange?.(
          fileQueueRef.current.filter((entry) => entry.status === "uploading")
            .length,
        );
      })
      .catch(() => {
        delete uploadPromisesRef.current[entryId];
        setPendingUploads((count) => Math.max(0, count - 1));
        onUploadStateChange?.(
          fileQueueRef.current.filter((entry) => entry.status === "uploading")
            .length,
        );
      });
  };

  const addFilesToQueue = (files: FileList | File[]) => {
    const additions: QueuedFileEntry[] = [];
    Array.from(files).forEach((file) => {
      if (!file) return;
      if (file.size > MAX_UPLOAD_BYTES) {
        setFileError(
          `${t.form.errorFileTooLarge(maxUploadMbDisplay)} (${file.name})`,
        );
        return;
      }
      const ext = file.name?.split(".").pop()?.toLowerCase() ?? "";
      const normalizedExt = ext ? `.${ext}` : "";
      if (!SUPPORTED_BOOK_EXTENSIONS.has(normalizedExt)) {
        return;
      }
      const id =
        typeof crypto !== "undefined" && typeof crypto.randomUUID === "function"
          ? crypto.randomUUID()
          : `queued-${Date.now()}-${Math.random().toString(16).slice(2)}`;
      additions.push({
        id,
        file,
        name: file.name,
        size: file.size,
        status: "uploading",
      });
    });
    if (additions.length === 0) {
      return;
    }
    setFileError(null);
    setShowMissingFileError(false);
    setFileQueueSafe((prev) => [...prev, ...additions]);
    additions.forEach((entry) => startUploadForEntry(entry.id, entry.file));
  };

  const removeFromQueue = (entryId: string) => {
    setFileQueueSafe((prev) => prev.filter((entry) => entry.id !== entryId));
  };

  const moveEntry = (entryId: string, delta: number) => {
    setFileQueueSafe((prev) => {
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
    setFileQueueSafe((prev) => {
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
      const insertIndex =
        constrained > currentIndex ? constrained - 1 : constrained;
      next.splice(insertIndex, 0, item);
      return next;
    });
  };

  const handleSubmit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const initialEntries = fileQueueRef.current.filter(
      (entry) => entry.status !== "error",
    );
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
    const normalizeEdgeTier = (
      value: string,
    ): "slow" | "medium" | "fast" | "ultra" | undefined => {
      if (
        value === "slow" ||
        value === "medium" ||
        value === "fast" ||
        value === "ultra"
      ) {
        return value;
      }
      return undefined;
    };

    const sharedConfig: ConversionTemplate = {
      engine,
      voice: voice || undefined,
      model: model || undefined,
      chapters: chapters || undefined,
      sections: sections || undefined,
      fromChapterToEnd: fromChapterToEnd || undefined,
      fromChapterToChapter: fromChapterToChapter || undefined,
      priority: priority || undefined,
      footnoteMode,
      language:
        engineMeta.autoLanguage || !language || language === "auto"
          ? undefined
          : language,
      formattingCues,
      noParallel,
      maxPerformance,
      parallelSlots: parseOptionalInt(parallelSlots),
      chapterStallSeconds: parseOptionalNumber(chapterStallSeconds),
      edgeNetworkTier: normalizeEdgeTier(edgeNetworkTier),
      edgeChunkChars: parseOptionalInt(edgeChunkChars),
      edgeMaxSegmentSeconds: parseOptionalInt(edgeMaxSegmentSeconds),
      edgeEnableParallel,
      edgeAutoTune,
      edgeStableMode,
      coquiChunkChars: parseOptionalInt(coquiChunkChars),
      coquiMaxWorkers: parseOptionalInt(coquiMaxWorkers),
      coquiSafeMode,
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
      healthCheckIntervalSeconds: parseOptionalNumber(
        healthCheckIntervalSeconds,
      ),
      healthCheckSlowEdgeCps: parseOptionalNumber(healthCheckSlowEdgeCps),
      healthCheckSlowCps: parseOptionalNumber(healthCheckSlowCps),
      healthCheckHighCpu: parseOptionalNumber(healthCheckHighCpu),
      healthCheckHighMem: parseOptionalNumber(healthCheckHighMem),
      healthCheckOkCpu: parseOptionalNumber(healthCheckOkCpu),
      healthCheckOkMem: parseOptionalNumber(healthCheckOkMem),
      healthCheckSlowStreak: parseOptionalInt(healthCheckSlowStreak),
      uiLanguage: locale,
    };
    const readyEntries = fileQueueRef.current.filter(
      (entry) => entry.status === "ready",
    );
    if (readyEntries.length === 0) {
      setShowMissingFileError(true);
      return;
    }
    const payloads = readyEntries.map((entry) => {
      const hasUpload = Boolean(
        entry.uploadId && entry.uploadId.trim().length > 0,
      );
      return {
        ...sharedConfig,
        file: hasUpload ? null : entry.file,
        fileName: entry.file?.name ?? entry.name,
        uploadId: entry.uploadId,
      };
    });
    const [first, ...rest] = payloads;
    await onSubmit(first, { batchQueue: rest });
    setFileQueueSafe([]);
  };

  const translateLanguage = (code: string): string => {
    return t.form.languageOptions[code] ?? code.toUpperCase();
  };

  const handleEngineChange = (nextEngine: EngineOption) => {
    setEngine(nextEngine);
    const meta = getEngineMeta(nextEngine);
    // In auto mode, don't set a voice (will be selected automatically)
    if (nextEngine === "auto") {
      setVoice("");
      setLanguage("auto");
    } else {
      setVoice(meta.defaultVoice);
      setLanguage(meta.autoLanguage ? "auto" : (meta.languages[0] ?? ""));
    }
  };

  useEffect(() => {
    if (languageOptionsList.length === 0) {
      return;
    }
    if (!languageOptionsList.includes(language)) {
      setLanguage(languageOptionsList[0] ?? "");
    }
  }, [languageOptionsList, language]);

  useEffect(() => {
    if (typeof currentJob?.formattingCues === "boolean") {
      setFormattingCues(currentJob.formattingCues);
    }
  }, [currentJob?.formattingCues]);
  useEffect(() => {
    if (typeof currentJob?.noParallel === "boolean") {
      setNoParallel(currentJob.noParallel);
    }
  }, [currentJob?.noParallel]);

  const handleUseSample = async () => {
    try {
      const basePath = import.meta.env.BASE_URL || "/";
      const normalizedBase = basePath.endsWith("/") ? basePath : `${basePath}/`;
      const response = await fetch(`${normalizedBase}sample.epub`);
      const blob = await response.blob();
      const file = new File([blob], "sample.epub", {
        type: "application/epub+zip",
      });
      setShowMissingFileError(false);
      setFileError(null);
      addFilesToQueue([file]);
    } catch (error) {
      console.error("Failed to load sample book:", error);
    }
  };

  return (
    <form className="conversion-form" onSubmit={handleSubmit}>
      <input
        ref={folderInputRef}
        type="file"
        multiple
        style={{ display: "none" }}
        onChange={(event) => {
          const files = event.target.files;
          if (files && files.length > 0) {
            addFilesToQueue(files);
            event.target.value = "";
          }
        }}
      />
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
                event.target.value = "";
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
          <button
            type="button"
            onClick={() => folderInputRef.current?.click()}
            disabled={isSubmitting}
            className="button-secondary file-input-row__sample"
            style={{ marginLeft: "0.5rem" }}
          >
            {t.form.addFolderButton}
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
              <span className="file-queue__count">
                {t.form.fileQueueCount(fileQueue.length)}
              </span>
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
                  if (!draggingId || event.target !== event.currentTarget)
                    return;
                  event.preventDefault();
                  setDragOverInfo({ id: END_DROP_ID, position: "after" });
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
                  const dropBefore =
                    dragOverInfo?.id === entry.id &&
                    dragOverInfo.position === "before";
                  const dropAfter =
                    dragOverInfo?.id === entry.id &&
                    dragOverInfo.position === "after";
                  const itemClasses = [
                    "file-queue__item",
                    isDragging ? "file-queue__item--dragging" : "",
                    dropBefore ? "file-queue__item--drop-before" : "",
                    dropAfter ? "file-queue__item--drop-after" : "",
                  ]
                    .filter(Boolean)
                    .join(" ");
                  return (
                    <li
                      key={entry.id}
                      className={itemClasses}
                      draggable={fileQueue.length > 1 && !isSubmitting}
                      onDragStart={(event) => handleDragStart(event, entry.id)}
                      onDragOver={(event) =>
                        handleDragOverItem(event, entry.id)
                      }
                      onDrop={(event) => handleDropOnItem(event, entry.id)}
                      onDragEnd={handleDragEnd}
                    >
                      <div className="file-queue__meta">
                        <span className="file-queue__name" title={entry.name}>
                          {index + 1}. {entry.name}
                        </span>
                        {entry.bookTitle && (
                          <span className="file-queue__book-info">
                            <strong>{entry.bookTitle}</strong>
                            {entry.bookAuthor && (
                              <span> — {entry.bookAuthor}</span>
                            )}
                          </span>
                        )}
                        <span className="file-queue__details">
                          {formatFileSize(entry.size)} •{" "}
                          {entry.status === "ready" && (
                            <span>✅ {t.form.autoUploadReady}</span>
                          )}
                          {entry.status === "uploading" && (
                            <span>📤 {t.form.uploadingFile}</span>
                          )}
                          {entry.status === "error" && (
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
                    className={`file-queue__dropzone ${dragOverInfo?.id === END_DROP_ID ? "file-queue__dropzone--active" : ""}`}
                    onDragOver={(event) => {
                      if (!draggingId) return;
                      event.preventDefault();
                      setDragOverInfo({ id: END_DROP_ID, position: "after" });
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
              onChange={(event) =>
                handleEngineChange(event.target.value as EngineOption)
              }
            >
              {t.form.engineOptions.map((option) => (
                <option key={option.value} value={option.value}>
                  {option.label}
                </option>
              ))}
            </select>
            <p className="form-hint">
              {
                t.form.engineOptions.find((option) => option.value === engine)
                  ?.help
              }
            </p>
            <div className="engine-insight">
              <div className="engine-insight__item">
                <span className="engine-insight__label">
                  {t.form.defaultVoiceLabel}
                </span>
                <code className="engine-insight__value">
                  {engineMeta.defaultVoice}
                </code>
              </div>
              <div className="engine-insight__item">
                <span className="engine-insight__label">
                  {t.form.multilingualSupportLabel}
                </span>
                <span className="engine-insight__value">
                  {engineMeta.multiLingual
                    ? t.form.multilingualYes
                    : t.form.multilingualNo}
                </span>
              </div>
              <div className="engine-insight__item">
                <span className="engine-insight__label">
                  {engineMeta.autoLanguage
                    ? t.form.autoLanguageLabel
                    : t.form.manualLanguageLabel}
                </span>
              </div>
              {!engineMeta.autoLanguage && engineMeta.languages.length > 0 && (
                <div className="engine-insight__languages">
                  <span className="engine-insight__label">
                    {t.form.availableLanguagesLabel}:
                  </span>
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
              disabled={
                isSubmitting ||
                languageOptionsList.length === 0 ||
                engine === "auto"
              }
              onChange={(event) => setLanguage(event.target.value)}
            >
              {languageOptionsList.map((code) => (
                <option key={code} value={code}>
                  {translateLanguage(code)}
                </option>
              ))}
            </select>
            <p className="form-hint">
              {engine === "auto"
                ? locale === "pt"
                  ? "Language will be automatically detected from the book"
                  : "Language will be automatically detected from the book"
                : engineMeta.autoLanguage
                  ? t.form.languageNotRequired
                  : t.form.languageHint}
            </p>
          </fieldset>

          <fieldset className="form-row">
            <label htmlFor="voice">{t.form.voiceLabel}</label>
            <select
              id="voice"
              name="voice"
              value={voice}
              disabled={isSubmitting || engine === "auto"}
              onChange={(event) => setVoice(event.target.value)}
            >
              {engine === "auto" && (
                <option value="">
                  {locale === "pt"
                    ? "Automatic selection based on language"
                    : "Automatic selection based on language"}
                </option>
              )}
              {engine !== "auto" &&
                voiceSuggestions.map((voiceInfo) => {
                  const label =
                    voiceInfo.label && voiceInfo.label !== voiceInfo.name
                      ? `${voiceInfo.label} • ${voiceInfo.name}`
                      : (voiceInfo.label ?? voiceInfo.name);
                  return (
                    <option key={voiceInfo.name} value={voiceInfo.name}>
                      {label} {voiceInfo.multilingual ? "🌐" : ""}
                    </option>
                  );
                })}
            </select>
            <p className="form-hint">
              {engine === "auto"
                ? locale === "pt"
                  ? "Voice will be automatically selected based on detected language"
                  : "Voice will be automatically selected based on detected language"
                : currentVoiceMultilingual
                  ? `🌐 ${t.form.voiceHint} ${t.form.voiceMultilingualHint}`
                  : t.form.voiceHint}
            </p>
            {voiceLoading && <p className="form-hint">{t.form.voiceLoading}</p>}
            {voiceLoadFailed && (
              <p className="form-hint form-hint--warning">
                {t.form.voiceLoadFailed}
              </p>
            )}
          </fieldset>

          <fieldset className="form-row">
            <label htmlFor="formattingCuesToggle">
              {t.form.formattingCuesLabel}
            </label>
            <label className="form-toggle" htmlFor="formattingCuesToggle">
              <input
                id="formattingCuesToggle"
                type="checkbox"
                checked={formattingCues}
                disabled={isSubmitting}
                onChange={(event) => setFormattingCues(event.target.checked)}
              />
              <span>
                {formattingCues
                  ? t.form.formattingCuesOn
                  : t.form.formattingCuesOff}
              </span>
            </label>
            <p className="form-hint">{t.form.formattingCuesDescription}</p>
          </fieldset>

          <fieldset className="form-row">
            <label htmlFor="noParallelToggle">{t.form.noParallelLabel}</label>
            <label className="form-toggle" htmlFor="noParallelToggle">
              <input
                id="noParallelToggle"
                type="checkbox"
                checked={noParallel}
                disabled={isSubmitting}
                onChange={(event) => setNoParallel(event.target.checked)}
              />
              <span>
                {noParallel ? t.form.noParallelOn : t.form.noParallelOff}
              </span>
            </label>
            <p className="form-hint">{t.form.noParallelDescription}</p>
          </fieldset>

          <fieldset className="form-row">
            <label htmlFor="maxPerformanceToggle">
              {t.form.maxPerformanceLabel}
            </label>
            <label className="form-toggle" htmlFor="maxPerformanceToggle">
              <input
                id="maxPerformanceToggle"
                type="checkbox"
                checked={maxPerformance}
                disabled={isSubmitting}
                onChange={(event) => setMaxPerformance(event.target.checked)}
              />
              <span>
                {maxPerformance
                  ? t.form.maxPerformanceOn
                  : t.form.maxPerformanceOff}
              </span>
            </label>
            <p className="form-hint">{t.form.maxPerformanceDescription}</p>
          </fieldset>

          <fieldset className="form-row">
            <label htmlFor="parallelSlots">{t.form.parallelSlotsLabel}</label>
            <input
              id="parallelSlots"
              name="parallelSlots"
              type="number"
              min={1}
              placeholder={t.form.parallelSlotsPlaceholder}
              value={parallelSlots}
              disabled={isSubmitting || noParallel}
              onChange={(event) => setParallelSlots(event.target.value)}
            />
            <p className="form-hint">{t.form.parallelSlotsHint}</p>
          </fieldset>
          <fieldset className="form-row">
            <label htmlFor="chapterStallSeconds">
              {t.form.chapterStallSecondsLabel}
            </label>
            <input
              id="chapterStallSeconds"
              name="chapterStallSeconds"
              type="number"
              min={10}
              placeholder={t.form.chapterStallSecondsPlaceholder}
              value={chapterStallSeconds}
              disabled={isSubmitting || edgeStableMode}
              onChange={(event) => setChapterStallSeconds(event.target.value)}
            />
            <p className="form-hint">{t.form.chapterStallSecondsHint}</p>
          </fieldset>
          <fieldset className="form-row">
            <label htmlFor="edgeNetworkTier">
              {t.form.edgeNetworkTierLabel}
            </label>
            <select
              id="edgeNetworkTier"
              name="edgeNetworkTier"
              value={edgeNetworkTier}
              disabled={isSubmitting || edgeStableMode}
              onChange={(event) =>
                setEdgeNetworkTier(
                  event.target.value as
                    | ""
                    | "slow"
                    | "medium"
                    | "fast"
                    | "ultra",
                )
              }
            >
              <option value="">{t.form.edgeNetworkTierAuto}</option>
              <option value="slow">{t.form.edgeNetworkTierSlow}</option>
              <option value="medium">{t.form.edgeNetworkTierMedium}</option>
              <option value="fast">{t.form.edgeNetworkTierFast}</option>
              <option value="ultra">{t.form.edgeNetworkTierUltra}</option>
            </select>
            <p className="form-hint">{t.form.edgeNetworkTierHint}</p>
          </fieldset>

          <fieldset className="form-field">
            <legend className="form-legend">{t.form.engineTuningLegend}</legend>
            <div className="form-row">
              <label htmlFor="model">{t.form.modelLabel}</label>
              <input
                id="model"
                name="model"
                placeholder={t.form.modelPlaceholder}
                value={model}
                disabled={isSubmitting}
                onChange={(event) => setModel(event.target.value)}
              />
              <p className="form-hint">{t.form.modelHint}</p>
            </div>
            <div className="form-row">
              <label htmlFor="edgeChunkChars">
                {t.form.edgeChunkCharsLabel}
              </label>
              <input
                id="edgeChunkChars"
                name="edgeChunkChars"
                type="number"
                min={4000}
                placeholder={t.form.edgeChunkCharsPlaceholder}
                value={edgeChunkChars}
                disabled={isSubmitting}
                onChange={(event) => setEdgeChunkChars(event.target.value)}
              />
              <p className="form-hint">{t.form.edgeChunkCharsHint}</p>
            </div>
            <div className="form-row">
              <label htmlFor="edgeMaxSegmentSeconds">
                {t.form.edgeMaxSegmentSecondsLabel}
              </label>
              <input
                id="edgeMaxSegmentSeconds"
                name="edgeMaxSegmentSeconds"
                type="number"
                min={30}
                placeholder={t.form.edgeMaxSegmentSecondsPlaceholder}
                value={edgeMaxSegmentSeconds}
                disabled={isSubmitting}
                onChange={(event) =>
                  setEdgeMaxSegmentSeconds(event.target.value)
                }
              />
              <p className="form-hint">{t.form.edgeMaxSegmentSecondsHint}</p>
            </div>
            <div className="form-row">
              <label htmlFor="edgeEnableParallelToggle">
                {t.form.edgeEnableParallelLabel}
              </label>
              <label className="form-toggle" htmlFor="edgeEnableParallelToggle">
                <input
                  id="edgeEnableParallelToggle"
                  type="checkbox"
                  checked={edgeEnableParallel}
                  disabled={isSubmitting || noParallel}
                  onChange={(event) =>
                    setEdgeEnableParallel(event.target.checked)
                  }
                />
                <span>
                  {edgeEnableParallel
                    ? t.form.edgeEnableParallelOn
                    : t.form.edgeEnableParallelOff}
                </span>
              </label>
              <p className="form-hint">{t.form.edgeEnableParallelHint}</p>
            </div>
            <div className="form-row">
              <label htmlFor="edgeAutoTuneToggle">
                {t.form.edgeAutoTuneLabel}
              </label>
              <label className="form-toggle" htmlFor="edgeAutoTuneToggle">
                <input
                  id="edgeAutoTuneToggle"
                  type="checkbox"
                  checked={edgeAutoTune}
                  disabled={isSubmitting}
                  onChange={(event) => setEdgeAutoTune(event.target.checked)}
                />
                <span>
                  {edgeAutoTune
                    ? t.form.edgeAutoTuneOn
                    : t.form.edgeAutoTuneOff}
                </span>
              </label>
              <p className="form-hint">{t.form.edgeAutoTuneHint}</p>
            </div>
            <div className="form-row">
              <label htmlFor="edgeStableModeToggle">
                {t.form.edgeStableModeLabel}
              </label>
              <label className="form-toggle" htmlFor="edgeStableModeToggle">
                <input
                  id="edgeStableModeToggle"
                  type="checkbox"
                  checked={edgeStableMode}
                  disabled={isSubmitting}
                  onChange={(event) => {
                    const next = event.target.checked;
                    setEdgeStableMode(next);
                    if (next) {
                      if (!chapterStallSeconds) {
                        setChapterStallSeconds("60");
                      }
                      if (!edgeNetworkTier) {
                        setEdgeNetworkTier("slow");
                      }
                    }
                  }}
                />
                <span>
                  {edgeStableMode
                    ? t.form.edgeStableModeOn
                    : t.form.edgeStableModeOff}
                </span>
              </label>
              <p className="form-hint">{t.form.edgeStableModeHint}</p>
            </div>
            <div className="form-row">
              <label htmlFor="coquiChunkChars">
                {t.form.coquiChunkCharsLabel}
              </label>
              <input
                id="coquiChunkChars"
                name="coquiChunkChars"
                type="number"
                min={800}
                placeholder={t.form.coquiChunkCharsPlaceholder}
                value={coquiChunkChars}
                disabled={isSubmitting}
                onChange={(event) => setCoquiChunkChars(event.target.value)}
              />
              <p className="form-hint">{t.form.coquiChunkCharsHint}</p>
            </div>
            <div className="form-row">
              <label htmlFor="coquiMaxWorkers">
                {t.form.coquiMaxWorkersLabel}
              </label>
              <input
                id="coquiMaxWorkers"
                name="coquiMaxWorkers"
                type="number"
                min={1}
                placeholder={t.form.coquiMaxWorkersPlaceholder}
                value={coquiMaxWorkers}
                disabled={isSubmitting}
                onChange={(event) => setCoquiMaxWorkers(event.target.value)}
              />
              <p className="form-hint">{t.form.coquiMaxWorkersHint}</p>
            </div>
            <div className="form-row">
              <label htmlFor="coquiSafeModeToggle">
                {t.form.coquiSafeModeLabel}
              </label>
              <label className="form-toggle" htmlFor="coquiSafeModeToggle">
                <input
                  id="coquiSafeModeToggle"
                  type="checkbox"
                  checked={coquiSafeMode}
                  disabled={isSubmitting}
                  onChange={(event) => setCoquiSafeMode(event.target.checked)}
                />
                <span>
                  {coquiSafeMode
                    ? t.form.coquiSafeModeOn
                    : t.form.coquiSafeModeOff}
                </span>
              </label>
              <p className="form-hint">{t.form.coquiSafeModeHint}</p>
            </div>
            <div className="form-row">
              <label htmlFor="piperMaxProcs">{t.form.piperMaxProcsLabel}</label>
              <input
                id="piperMaxProcs"
                name="piperMaxProcs"
                type="number"
                min={1}
                placeholder={t.form.piperMaxProcsPlaceholder}
                value={piperMaxProcs}
                disabled={isSubmitting}
                onChange={(event) => setPiperMaxProcs(event.target.value)}
              />
              <p className="form-hint">{t.form.piperMaxProcsHint}</p>
            </div>
          </fieldset>

          <fieldset className="form-field">
            <legend className="form-legend">{t.form.audioLegend}</legend>
            <div className="form-row">
              <label htmlFor="bitrate">{t.form.bitrateLabel}</label>
              <input
                id="bitrate"
                name="bitrate"
                placeholder={t.form.bitratePlaceholder}
                value={bitrate}
                disabled={isSubmitting}
                onChange={(event) => setBitrate(event.target.value)}
              />
              <p className="form-hint">{t.form.bitrateHint}</p>
            </div>
            <div className="form-row">
              <label htmlFor="sampleRate">{t.form.sampleRateLabel}</label>
              <input
                id="sampleRate"
                name="sampleRate"
                type="number"
                min={8000}
                placeholder={t.form.sampleRatePlaceholder}
                value={sampleRate}
                disabled={isSubmitting}
                onChange={(event) => setSampleRate(event.target.value)}
              />
              <p className="form-hint">{t.form.sampleRateHint}</p>
            </div>
            <div className="form-row">
              <label htmlFor="channels">{t.form.channelsLabel}</label>
              <select
                id="channels"
                name="channels"
                value={channels}
                disabled={isSubmitting}
                onChange={(event) => setChannels(event.target.value)}
              >
                <option value="1">{t.form.channelsMono}</option>
                <option value="2">{t.form.channelsStereo}</option>
              </select>
              <p className="form-hint">{t.form.channelsHint}</p>
            </div>
          </fieldset>

          <fieldset className="form-field">
            <legend className="form-legend">{t.form.processingLegend}</legend>
            <div className="form-row">
              <label htmlFor="verboseToggle">{t.form.verboseLabel}</label>
              <label className="form-toggle" htmlFor="verboseToggle">
                <input
                  id="verboseToggle"
                  type="checkbox"
                  checked={verbose}
                  disabled={isSubmitting}
                  onChange={(event) => setVerbose(event.target.checked)}
                />
                <span>{verbose ? t.form.verboseOn : t.form.verboseOff}</span>
              </label>
              <p className="form-hint">{t.form.verboseDescription}</p>
            </div>
            <div className="form-row">
              <label htmlFor="clearCacheToggle">{t.form.clearCacheLabel}</label>
              <label className="form-toggle" htmlFor="clearCacheToggle">
                <input
                  id="clearCacheToggle"
                  type="checkbox"
                  checked={clearCache}
                  disabled={isSubmitting}
                  onChange={(event) => setClearCache(event.target.checked)}
                />
                <span>
                  {clearCache ? t.form.clearCacheOn : t.form.clearCacheOff}
                </span>
              </label>
              <p className="form-hint">{t.form.clearCacheDescription}</p>
            </div>
            <div className="form-row">
              <label htmlFor="forceReprocessToggle">
                {t.form.forceReprocessLabel}
              </label>
              <label className="form-toggle" htmlFor="forceReprocessToggle">
                <input
                  id="forceReprocessToggle"
                  type="checkbox"
                  checked={forceReprocess}
                  disabled={isSubmitting}
                  onChange={(event) => setForceReprocess(event.target.checked)}
                />
                <span>
                  {forceReprocess
                    ? t.form.forceReprocessOn
                    : t.form.forceReprocessOff}
                </span>
              </label>
              <p className="form-hint">{t.form.forceReprocessDescription}</p>
            </div>
            <div className="form-row">
              <label htmlFor="filterChaptersToggle">
                {t.form.filterChaptersLabel}
              </label>
              <label className="form-toggle" htmlFor="filterChaptersToggle">
                <input
                  id="filterChaptersToggle"
                  type="checkbox"
                  checked={filterChapters}
                  disabled={isSubmitting}
                  onChange={(event) => setFilterChapters(event.target.checked)}
                />
                <span>
                  {filterChapters
                    ? t.form.filterChaptersOn
                    : t.form.filterChaptersOff}
                </span>
              </label>
              <p className="form-hint">{t.form.filterChaptersDescription}</p>
            </div>
          </fieldset>

          <fieldset className="form-field">
            <legend className="form-legend">
              {t.form.languageDetectionLegend}
            </legend>
            <div className="form-row">
              <label htmlFor="useLanguageDetectionToggle">
                {t.form.languageDetectionLabel}
              </label>
              <label
                className="form-toggle"
                htmlFor="useLanguageDetectionToggle"
              >
                <input
                  id="useLanguageDetectionToggle"
                  type="checkbox"
                  checked={useLanguageDetection}
                  disabled={isSubmitting}
                  onChange={(event) =>
                    setUseLanguageDetection(event.target.checked)
                  }
                />
                <span>
                  {useLanguageDetection
                    ? t.form.languageDetectionOn
                    : t.form.languageDetectionOff}
                </span>
              </label>
              <p className="form-hint">{t.form.languageDetectionDescription}</p>
            </div>
            <div className="form-row">
              <label htmlFor="prioritizePrimaryLanguageToggle">
                {t.form.prioritizePrimaryLanguageLabel}
              </label>
              <label
                className="form-toggle"
                htmlFor="prioritizePrimaryLanguageToggle"
              >
                <input
                  id="prioritizePrimaryLanguageToggle"
                  type="checkbox"
                  checked={prioritizePrimaryLanguage}
                  disabled={isSubmitting}
                  onChange={(event) =>
                    setPrioritizePrimaryLanguage(event.target.checked)
                  }
                />
                <span>
                  {prioritizePrimaryLanguage
                    ? t.form.prioritizePrimaryLanguageOn
                    : t.form.prioritizePrimaryLanguageOff}
                </span>
              </label>
              <p className="form-hint">
                {t.form.prioritizePrimaryLanguageDescription}
              </p>
            </div>
          </fieldset>

          <fieldset className="form-field">
            <legend className="form-legend">{t.form.healthCheckLegend}</legend>
            <div className="form-row">
              <label htmlFor="healthCheckIntervalSeconds">
                {t.form.healthCheckIntervalLabel}
              </label>
              <input
                id="healthCheckIntervalSeconds"
                name="healthCheckIntervalSeconds"
                type="number"
                min={10}
                step={1}
                placeholder={t.form.healthCheckIntervalPlaceholder}
                value={healthCheckIntervalSeconds}
                disabled={isSubmitting}
                onChange={(event) =>
                  setHealthCheckIntervalSeconds(event.target.value)
                }
              />
              <p className="form-hint">{t.form.healthCheckIntervalHint}</p>
            </div>
            <div className="form-row">
              <label htmlFor="healthCheckSlowEdgeCps">
                {t.form.healthCheckSlowEdgeCpsLabel}
              </label>
              <input
                id="healthCheckSlowEdgeCps"
                name="healthCheckSlowEdgeCps"
                type="number"
                min={10}
                step={1}
                placeholder={t.form.healthCheckSlowEdgeCpsPlaceholder}
                value={healthCheckSlowEdgeCps}
                disabled={isSubmitting}
                onChange={(event) =>
                  setHealthCheckSlowEdgeCps(event.target.value)
                }
              />
              <p className="form-hint">{t.form.healthCheckSlowEdgeCpsHint}</p>
            </div>
            <div className="form-row">
              <label htmlFor="healthCheckSlowCps">
                {t.form.healthCheckSlowCpsLabel}
              </label>
              <input
                id="healthCheckSlowCps"
                name="healthCheckSlowCps"
                type="number"
                min={10}
                step={1}
                placeholder={t.form.healthCheckSlowCpsPlaceholder}
                value={healthCheckSlowCps}
                disabled={isSubmitting}
                onChange={(event) => setHealthCheckSlowCps(event.target.value)}
              />
              <p className="form-hint">{t.form.healthCheckSlowCpsHint}</p>
            </div>
            <div className="form-row">
              <label htmlFor="healthCheckHighCpu">
                {t.form.healthCheckHighCpuLabel}
              </label>
              <input
                id="healthCheckHighCpu"
                name="healthCheckHighCpu"
                type="number"
                min={30}
                max={100}
                step={1}
                placeholder={t.form.healthCheckHighCpuPlaceholder}
                value={healthCheckHighCpu}
                disabled={isSubmitting}
                onChange={(event) => setHealthCheckHighCpu(event.target.value)}
              />
              <p className="form-hint">{t.form.healthCheckHighCpuHint}</p>
            </div>
            <div className="form-row">
              <label htmlFor="healthCheckHighMem">
                {t.form.healthCheckHighMemLabel}
              </label>
              <input
                id="healthCheckHighMem"
                name="healthCheckHighMem"
                type="number"
                min={30}
                max={100}
                step={1}
                placeholder={t.form.healthCheckHighMemPlaceholder}
                value={healthCheckHighMem}
                disabled={isSubmitting}
                onChange={(event) => setHealthCheckHighMem(event.target.value)}
              />
              <p className="form-hint">{t.form.healthCheckHighMemHint}</p>
            </div>
            <div className="form-row">
              <label htmlFor="healthCheckOkCpu">
                {t.form.healthCheckOkCpuLabel}
              </label>
              <input
                id="healthCheckOkCpu"
                name="healthCheckOkCpu"
                type="number"
                min={10}
                max={100}
                step={1}
                placeholder={t.form.healthCheckOkCpuPlaceholder}
                value={healthCheckOkCpu}
                disabled={isSubmitting}
                onChange={(event) => setHealthCheckOkCpu(event.target.value)}
              />
              <p className="form-hint">{t.form.healthCheckOkCpuHint}</p>
            </div>
            <div className="form-row">
              <label htmlFor="healthCheckOkMem">
                {t.form.healthCheckOkMemLabel}
              </label>
              <input
                id="healthCheckOkMem"
                name="healthCheckOkMem"
                type="number"
                min={10}
                max={100}
                step={1}
                placeholder={t.form.healthCheckOkMemPlaceholder}
                value={healthCheckOkMem}
                disabled={isSubmitting}
                onChange={(event) => setHealthCheckOkMem(event.target.value)}
              />
              <p className="form-hint">{t.form.healthCheckOkMemHint}</p>
            </div>
            <div className="form-row">
              <label htmlFor="healthCheckSlowStreak">
                {t.form.healthCheckSlowStreakLabel}
              </label>
              <input
                id="healthCheckSlowStreak"
                name="healthCheckSlowStreak"
                type="number"
                min={1}
                max={6}
                step={1}
                placeholder={t.form.healthCheckSlowStreakPlaceholder}
                value={healthCheckSlowStreak}
                disabled={isSubmitting}
                onChange={(event) =>
                  setHealthCheckSlowStreak(event.target.value)
                }
              />
              <p className="form-hint">{t.form.healthCheckSlowStreakHint}</p>
            </div>
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
            <label htmlFor="fromChapterToEnd">
              {t.form.fromChapterToEndLabel}
            </label>
            <input
              id="fromChapterToEnd"
              name="fromChapterToEnd"
              placeholder={t.form.fromChapterToEndPlaceholder}
              value={fromChapterToEnd}
              disabled={isSubmitting}
              onChange={(event) => setFromChapterToEnd(event.target.value)}
            />
            <p className="form-hint">{t.form.fromChapterToEndHint}</p>
          </fieldset>

          <fieldset className="form-row">
            <label htmlFor="fromChapterToChapter">
              {t.form.fromChapterToChapterLabel}
            </label>
            <input
              id="fromChapterToChapter"
              name="fromChapterToChapter"
              placeholder={t.form.fromChapterToChapterPlaceholder}
              value={fromChapterToChapter}
              disabled={isSubmitting}
              onChange={(event) => setFromChapterToChapter(event.target.value)}
            />
            <p className="form-hint">{t.form.fromChapterToChapterHint}</p>
          </fieldset>

          <fieldset className="form-row">
            <label htmlFor="sections">{t.form.sectionsLabel}</label>
            <input
              id="sections"
              name="sections"
              placeholder={t.form.sectionsPlaceholder}
              value={sections}
              disabled={isSubmitting}
              onChange={(event) => setSections(event.target.value)}
            />
            <p className="form-hint">{t.form.sectionsHint}</p>
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
                  <label
                    key={option.value}
                    className="segmented-list__item"
                    htmlFor={inputId}
                  >
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
                      <span className="segmented-list__title">
                        {option.title}
                      </span>
                      <span className="segmented-list__description">
                        {option.description}
                      </span>
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

      {estimatedDuration && !isSubmitting && (
        <p className="form-estimate-hint">
          {t.form.estimatedDuration(estimatedDuration)}
        </p>
      )}
      <button type="submit" disabled={disableSubmit} className="form-submit">
        {isSubmitting || Object.keys(uploadPromisesRef.current).length > 0
          ? t.form.submitBusy
          : t.form.submitIdle}
      </button>
    </form>
  );
}
