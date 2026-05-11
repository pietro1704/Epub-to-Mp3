import type {
  EngineOption,
  FootnoteMode,
  ChapterProgressStatus,
} from "../types/conversion";

export type Locale = "en" | "pt";

export interface EngineOptionText {
  value: EngineOption;
  label: string;
  help: string;
}

export interface EngineDetailText {
  tagline: string;
  quality: string;
  speed: string;
  requirements: string;
  bestVoice: string;
  bestVoiceNote: string;
  pros: string[];
  cons: string[];
  languages: string;
}

export type EngineDetails = Record<string, EngineDetailText>;

export interface FootnoteOptionText {
  value: FootnoteMode;
  title: string;
  description: string;
}

export interface TopBarText {
  ariaLabel: string;
  themeLabel: string;
  themeLight: string;
  themeDark: string;
  themeAuto: string;
  localeLabel: string;
  localeEnglish: string;
  localePortuguese: string;
  localeAuto: string;
}

export interface HeroHighlight {
  title: string;
  description: string;
}

export interface HeroText {
  badge: string;
  title: string;
  subtitle: string;
  highlights: HeroHighlight[];
}

export interface TabsText {
  setup: {
    label: string;
    description: string;
    panelTitle: string;
    panelDescription: string;
    savedBatchTitle: (count: number) => string;
    savedBatchResume: string;
    savedBatchDismiss: string;
    savedBatchNeedsReupload: (count: number) => string;
  };
  progress: {
    label: string;
    description: string;
    panelTitle: string;
    panelDescription: string;
    activeBadge?: string;
    backButton: string;
    viewDownloads: string;
  };
  downloads: {
    label: string;
    description: string;
    panelTitle: string;
    panelDescription: string;
    footer: string;
    backButton: string;
    followConversion: string;
  };
}

export interface ActiveConversionText {
  title: string;
  currentLabel: string;
  etaLabel: string;
  queueHint: string;
  description: string;
  viewProgress: string;
  cancel: string;
  skip: string;
  engineLabel: string;
  voiceLabel: string;
  languageLabel: string;
}

export interface FormText {
  fileLabel: string;
  fileHint: string;
  fileQueueLabel: string;
  fileQueueEmpty: string;
  fileQueueWithCurrent: (title: string) => string;
  fileQueueCount: (count: number) => string;
  fileQueueRemove: string;
  fileQueueMoveUp: string;
  fileQueueMoveDown: string;
  fileQueueReorderHint: string;
  useSampleButton: string;
  addFolderButton: string;
  engineLabel: string;
  engineOptions: EngineOptionText[];
  engineDetails: EngineDetails;
  autoEngineComparisonTitle: string;
  autoEngineComparisonNote: string;
  comparisonHeaders: {
    engine: string;
    quality: string;
    speed: string;
    languages: string;
    needs: string;
  };
  voicePreviewPlay: string;
  voicePreviewStop: string;
  voicePreviewLoading: string;
  voicePreviewError: string;
  defaultVoiceLabel: string;
  multilingualSupportLabel: string;
  multilingualYes: string;
  multilingualNo: string;
  autoLanguageLabel: string;
  manualLanguageLabel: string;
  voiceLabel: string;
  voicePlaceholder: string;
  voiceHint: string;
  voiceMultilingualHint: string;
  voiceLoading: string;
  voiceLoadFailed: string;
  chaptersLabel: string;
  chaptersPlaceholder: string;
  chaptersHint: string;
  fromChapterToEndLabel: string;
  fromChapterToEndPlaceholder: string;
  fromChapterToEndHint: string;
  fromChapterToChapterLabel: string;
  fromChapterToChapterPlaceholder: string;
  fromChapterToChapterHint: string;
  priorityLabel: string;
  priorityPlaceholder: string;
  priorityHint: string;
  footnoteLegend: string;
  footnoteOptions: FootnoteOptionText[];
  languageLabel: string;
  languagePlaceholder: string;
  languageHint: string;
  languageNotRequired: string;
  languageAutoDetected: string;
  voiceAutoSelected: string;
  voiceAutoOption: string;
  languageOptions: Record<string, string>;
  availableLanguagesLabel: string;
  errorNoFile: string;
  autoUploadHint: string;
  autoUploadPending: string;
  autoUploadReady: string;
  uploadingFile: string;
  advancedSummary: string;
  errorFileTooLarge: (limitMb: number) => string;
  submitIdle: string;
  submitBusy: string;
  estimatedDuration: (formatted: string) => string;
  formattingCuesLabel: string;
  formattingCuesDescription: string;
  formattingCuesOn: string;
  formattingCuesOff: string;
  characterVoicesLabel: string;
  characterVoicesDescription: string;
  characterVoicesOn: string;
  characterVoicesOff: string;
  narratorVoiceLabel: string;
  characterVoiceLabel: string;
  characterVoicesAutoOption: string;
  exportToIphoneLabel: string;
  exportToIphoneDescription: string;
  exportToIphoneOn: string;
  exportToIphoneOff: string;
  noParallelLabel: string;
  noParallelDescription: string;
  noParallelOn: string;
  noParallelOff: string;
  multiEngineParallelLabel: string;
  multiEngineParallelDescription: string;
  multiEngineParallelOn: string;
  multiEngineParallelOff: string;
  maxPerformanceLabel: string;
  maxPerformanceDescription: string;
  maxPerformanceOn: string;
  maxPerformanceOff: string;
  parallelSlotsLabel: string;
  parallelSlotsPlaceholder: string;
  parallelSlotsHint: string;
  chapterStallSecondsLabel: string;
  chapterStallSecondsPlaceholder: string;
  chapterStallSecondsHint: string;
  edgeNetworkTierLabel: string;
  edgeNetworkTierHint: string;
  edgeNetworkTierAuto: string;
  edgeNetworkTierSlow: string;
  edgeNetworkTierMedium: string;
  edgeNetworkTierFast: string;
  edgeNetworkTierUltra: string;
  engineTuningLegend: string;
  modelLabel: string;
  modelPlaceholder: string;
  modelHint: string;
  edgeChunkCharsLabel: string;
  edgeChunkCharsPlaceholder: string;
  edgeChunkCharsHint: string;
  edgeMaxSegmentSecondsLabel: string;
  edgeMaxSegmentSecondsPlaceholder: string;
  edgeMaxSegmentSecondsHint: string;
  edgeEnableParallelLabel: string;
  edgeEnableParallelHint: string;
  edgeEnableParallelOn: string;
  edgeEnableParallelOff: string;
  edgeAutoTuneLabel: string;
  edgeAutoTuneHint: string;
  edgeAutoTuneOn: string;
  edgeAutoTuneOff: string;
  edgeStableModeLabel: string;
  edgeStableModeHint: string;
  edgeStableModeOn: string;
  edgeStableModeOff: string;
  engineChainFallbackLabel: string;
  engineChainFallbackHint: string;
  engineChainFallbackOn: string;
  engineChainFallbackOff: string;
  piperMaxProcsLabel: string;
  piperMaxProcsPlaceholder: string;
  piperMaxProcsHint: string;
  audioLegend: string;
  bitrateLabel: string;
  bitratePlaceholder: string;
  bitrateHint: string;
  sampleRateLabel: string;
  sampleRatePlaceholder: string;
  sampleRateHint: string;
  channelsLabel: string;
  channelsHint: string;
  channelsMono: string;
  channelsStereo: string;
  processingLegend: string;
  verboseLabel: string;
  verboseDescription: string;
  verboseOn: string;
  verboseOff: string;
  clearCacheLabel: string;
  clearCacheDescription: string;
  clearCacheOn: string;
  clearCacheOff: string;
  forceReprocessLabel: string;
  forceReprocessDescription: string;
  forceReprocessOn: string;
  forceReprocessOff: string;
  filterChaptersLabel: string;
  filterChaptersDescription: string;
  filterChaptersOn: string;
  filterChaptersOff: string;
  languageDetectionLegend: string;
  languageDetectionLabel: string;
  languageDetectionDescription: string;
  languageDetectionOn: string;
  languageDetectionOff: string;
  prioritizePrimaryLanguageLabel: string;
  prioritizePrimaryLanguageDescription: string;
  prioritizePrimaryLanguageOn: string;
  prioritizePrimaryLanguageOff: string;
  healthCheckLegend: string;
  healthCheckIntervalLabel: string;
  healthCheckIntervalPlaceholder: string;
  healthCheckIntervalHint: string;
  healthCheckSlowEdgeCpsLabel: string;
  healthCheckSlowEdgeCpsPlaceholder: string;
  healthCheckSlowEdgeCpsHint: string;
  healthCheckSlowCpsLabel: string;
  healthCheckSlowCpsPlaceholder: string;
  healthCheckSlowCpsHint: string;
  healthCheckHighCpuLabel: string;
  healthCheckHighCpuPlaceholder: string;
  healthCheckHighCpuHint: string;
  healthCheckHighMemLabel: string;
  healthCheckHighMemPlaceholder: string;
  healthCheckHighMemHint: string;
  healthCheckOkCpuLabel: string;
  healthCheckOkCpuPlaceholder: string;
  healthCheckOkCpuHint: string;
  healthCheckOkMemLabel: string;
  healthCheckOkMemPlaceholder: string;
  healthCheckOkMemHint: string;
  healthCheckSlowStreakLabel: string;
  healthCheckSlowStreakPlaceholder: string;
  healthCheckSlowStreakHint: string;
  sectionsLabel: string;
  sectionsPlaceholder: string;
  sectionsHint: string;
}

export interface ProgressQueueText {
  title: string;
  subtitle: string;
  inputLabel: string;
  hint: string;
  addFolderButton: string;
  success: (count: number) => string;
  errorFallback: string;
  phaseActive: string;
  phaseSuccess: string;
  displayCurrentLabel: string;
  displayQueueLabel: (count: number) => string;
  displayMoreLabel: (count: number) => string;
  displayResumeButton: string;
  displayClearButton: string;
  displayPausedBadge: string;
  displayShowLess: string;
  displayMoveUp: string;
  displayMoveDown: string;
}

export interface StatusText {
  phases: Record<
    | "idle"
    | "submitting"
    | "polling"
    | "success"
    | "error"
    | "cancelling"
    | "cancelled",
    string
  >;
  jobLabel: (jobId: string) => string;
  placeholder: string;
  errorPrefix: string;
  toggleShow: string;
  toggleHide: string;
  etaLabel: string;
  etaCalculating: string;
  etaSoon: string;
  etaDone: string;
  cancelButton: string;
  cancelButtonPending: string;
  skipButton: string;
  progressLabel: string;
  summaryTitle: string;
  summaryLanguage: string;
  summaryChapters: string;
  summaryCurrent: string;
  summaryHint: string;
  summaryProgress: string;
  summaryParallel: string;
  chapterProgressTitle: string;
  expandAllChapters: string;
  collapseAllChapters: string;
  showAllText: string;
  hideAllText: string;
  scrollToTop: string;
  downloadFullText: string;
  searchPlaceholder: string;
  searchCount: (count: number) => string;
  searchPrev: string;
  searchNext: string;
  readerTitle: string;
  readerReadButton: string;
  readerUnavailable: string;
  readerStillExtracting: string;
  readerExtractionFailed: string;
  readerLoading: string;
  readerEmpty: string;
  readerOpen: string;
  readerClose: string;
  readerOpenPopup: string;
  readerExitPopup: string;
  readerChaptersTitle: string;
  readerPageLabel: (current: number, total: number) => string;
  readerPrevPage: string;
  readerNextPage: string;
  readerFollowAudioLabel: string;
  readerFollowAudioOn: string;
  readerFollowAudioOff: string;
  readerThemeLabel: string;
  readerThemePaper: string;
  readerThemeMist: string;
  readerThemeInk: string;
  readerFontSizeLabel: string;
  readerFontFamilyLabel: string;
  readerFontFamilySerif: string;
  readerFontFamilySans: string;
  readerLineHeightLabel: string;
  readerWidthLabel: string;
  readerNowReading: string;
  readerWaitingSegment: string;
  readerPlaying: string;
  readerPaused: string;
  readerSegmentLabel: (index: number) => string;
  readerChapterCount: (count: number) => string;
  readerAudioOnChapter: (index: number) => string;
  readerRetryLoad: string;
  uiHealthTitle: string;
  uiHealthSubtitle: (count: number) => string;
  uiHealthClear: string;
  uiHealthDismiss: string;
  chapterStatuses: Record<ChapterProgressStatus, string>;
  chapterCompletedIn: (value: string) => string;
  chapterGoToCurrent: string;
  chapterGoToCurrentTitle: string;
  chapterFullAudio: string;
  chapterSegmentsTitle: string;
  chapterSegmentCount: (count: number) => string;
  chapterSegmentsNone: string;
  chapterSegmentsWaiting: string;
  chapterSegmentsLoading: string;
  chapterSegmentTitle: (index: number) => string;
  chapterSegmentShowText: string;
  chapterSegmentHideText: string;
  chapterSegmentText: string;
  chapterSegmentsEmpty: string;
  chapterAudioUnsupported: string;
  chapterEngineLabel: (engine: string) => string;
  bookFallbackTitle: string;
  bookFallbackAuthor: string;
  uploadingFiles: string;
  errorCategoryHints: Record<string, string>;
  ttsEngineLabel: string;
  speedLabel: string;
  terminalLogLabel: string;
  coverPhaseSubmitting: string;
  coverPhasePolling: string;
  coverPhaseSuccess: string;
  coverPhaseError: string;
  coverPhaseDefault: string;
  cachedJobsTitle: string;
  cachedJobsClose: string;
  cachedJobsSingular: string;
  cachedJobsPlural: (count: number) => string;
  cachedJobsResume: string;
  cachedJobsRemove: (fileName: string) => string;
  cachedJobsJustNow: string;
  cachedJobsDaysAgo: (days: number) => string;
  cachedJobsHoursAgo: (hours: number) => string;
  cachedJobsMinutesAgo: (minutes: number) => string;
}

export interface ResumableJobsText {
  title: string;
  subtitle: string;
  empty: string;
  loading: string;
  resumeButton: string;
  removeButton: string;
  toggleMore: (expanded: boolean) => string;
  justNow: string;
  minutesAgo: (minutes: number) => string;
  hoursAgo: (hours: number) => string;
  daysAgo: (days: number) => string;
  engineLabel: (value: string) => string;
  voiceLabel: (value: string) => string;
  languageLabel: (value: string) => string;
}

export interface RecentJobsText {
  title: string;
  subtitle: string;
  resumeButton: string;
  downloadButton: string;
  viewAudiosButton: string;
  viewAudiosHint: string;
  empty: string;
  justNow: string;
  minutesAgo: (minutes: number) => string;
  hoursAgo: (hours: number) => string;
  daysAgo: (days: number) => string;
  stateLabels: Record<string, string>;
  completedAtLabel: (value: string) => string;
  durationLabel: (value: string) => string;
  removeButton: string;
}

export interface DownloadsText {
  placeholder: string;
  noDownloadsAfterSuccess: string;
  resetWithDownloads: string;
  resetWithoutDownloads: string;
  audioNotSupported: string;
  downloadChapter: string;
  downloadZip: string;
  downloadZipHint: (chapterCount: number) => string;
  orIndividual: string;
  downloadLog: string;
  viewLog: string;
  hideLog: string;
  logLoading: string;
  logError: (message: string) => string;
  viewingJobTitle: (title: string) => string;
  viewingJobSubtitle: string;
  viewingJobBackToCurrent: string;
  readyListTitle: string;
  readyListSubtitle: string;
  readyListAction: string;
  readyListDownloadAll: string;
  readyListDownloadAllHint: string;
  readyListItem: (count: number) => string;
  readyListAriaLabel: string;
  readyListTagCurrent: string;
  readyListTagPast: string;
  removeButton: string;
  readyNotificationTitle: string;
  readyNotificationBody: (title: string) => string;
  readyNotificationBodyFallback: string;
  shareTitle: string;
  shareSubtitle: (book: string) => string;
  shareWhatsapp: string;
  shareCopyLink: string;
  shareCopied: string;
  shareCopyError: string;
  shareNative: string;
  shareNativeUnavailable: string;
  shareUnavailable: string;
  shareMessage: (book: string) => string;
  readyListCompletedAt: (value: string) => string;
  readyListDuration: (value: string) => string;
  durationHours: (value: number) => string;
  durationMinutes: (value: number) => string;
  durationSeconds: (value: number) => string;
}

export interface LayoutText {
  footer: string;
  closeNotification: string;
  updateAvailable: (version: string) => string;
  updateInstall: string;
  updateInstalling: string;
  updateDismiss: string;
  updateInstallError: string;
  restartTitle: string;
  restartDescription: string;
  restartButton: string;
  restartProgress: string;
  restartConfirm: string;
  restartConfirmYes: string;
  restartConfirmNo: string;
  restartKeepCacheTitle: string;
  restartKeepCacheConfirm: string;
  restartKeepCacheYes: string;
  restartKeepCacheNo: string;
  restartKeepFinishedTitle: string;
  restartKeepFinishedConfirm: string;
  restartKeepFinishedYes: string;
  restartKeepFinishedNo: string;
  restartNotifyTitle: string;
  restartNotifyBody: string;
  restartErrorBody: string;
  helpToggle: string;
  helpTitle: string;
  helpClose: string;
  statsTitle: string;
  statsLoading: string;
  statsUptime: string;
  statsCpu: string;
  statsMemory: string;
  statsQueue: string;
  statsRunning: string;
  statsWorkers: string;
  statsRecommendation: string;
  statsGpu: string;
  statsError: string;
  statsOffline: string;
  statsLastUpdated: (value: string) => string;
  statsRetrying: (value: string) => string;
  statsTarget: string;
  statsGpuUsage: string;
  statsGpuVram: string;
  statsGpuTemp: string;
  tauriEngineWaiting: string;
  tauriEngineErrorTitle: string;
  tauriEngineRebuild: string;
  telemetryTitle: string;
  telemetryDescription: string;
  telemetryRefresh: string;
  telemetryRefreshing: string;
  telemetryErrorGeneric: string;
  telemetryEmptyState: string;
  telemetryEngineHeader: string;
  telemetrySamplesHeader: string;
  telemetryAvgHeader: string;
  telemetryMinHeader: string;
  telemetryMaxHeader: string;
  telemetryRankedLabel: string;
  telemetryTimelineTitle: string;
  telemetryTimelineEmpty: string;
  telemetryTimelineLatest: string;
  telemetryTotalSamples: (count: number) => string;
  telemetryUpdatedAt: (isoString: string) => string;
}

export interface FlowMessages {
  startUpload: string;
  startReuse: string;
  jobCreated: (jobId: string) => string;
  resuming: string;
  loadingCache?: string;
  completion: (count: number) => string;
  failure: (message: string) => string;
  error: (message: string) => string;
  defaultFailure: string;
  defaultError: string;
  cancelRequested: string;
  cancelled: string;
  skipped: string;
  cancelFailed: (message: string) => string;
  skipConfirm: string;
  backendOffline: string;
  backendOfflineDetails: string;
  backendConnecting: string;
  backendOfflineBanner: string;
  cachedRestoredSuccess: string;
  cancelConfirm: string;
  batchPosition: (index: number, total: number) => string;
  batchCancelled: (remaining: number) => string;
  notificationErrorTitle: string;
  notificationErrorBody: string;
  notificationCancelTitle: string;
  notificationCancelBody: string;
}

export interface Translations {
  locale: Locale;
  topBar: TopBarText;
  hero: HeroText;
  tabs: TabsText;
  activeConversion: ActiveConversionText;
  form: FormText;
  status: StatusText;
  resumableJobs: ResumableJobsText;
  recentJobs: RecentJobsText;
  downloads: DownloadsText;
  layout: LayoutText;
  flow: FlowMessages;
  queue: ProgressQueueText;
}

export const translations: Record<Locale, Translations> = {
  pt: {
    locale: "pt",
    topBar: {
      ariaLabel: "Preferências de tema e idioma",
      themeLabel: "Tema",
      themeLight: "Claro",
      themeDark: "Escuro",
      themeAuto: "Auto",
      localeLabel: "Idioma",
      localeEnglish: "Inglês",
      localePortuguese: "Português",
      localeAuto: "Auto",
    },
    resumableJobs: {
      title: "Retomar conversões inacabadas",
      subtitle:
        "Detectamos livros parcialmente convertidos. Clique para continuar de onde parou.",
      empty: "Nenhuma conversão pendente para retomar.",
      loading: "Carregando conversões pendentes...",
      resumeButton: "Continuar agora",
      removeButton: "Remover",
      toggleMore: (expanded: boolean) =>
        expanded ? "Mostrar menos" : "Ver todas",
      justNow: "agora mesmo",
      minutesAgo: (m: number) => `há ${m} min`,
      hoursAgo: (h: number) => `há ${h}h`,
      daysAgo: (d: number) => `há ${d} dia${d > 1 ? "s" : ""}`,
      engineLabel: (value: string) => `Motor: ${value}`,
      voiceLabel: (value: string) => `Voz: ${value}`,
      languageLabel: (value: string) => `Idioma: ${value}`,
    },
    recentJobs: {
      title: "⚡ Conversões recentes",
      subtitle:
        "Retome ou baixe rapidamente qualquer conversão salva no servidor.",
      resumeButton: "Retomar",
      downloadButton: "Baixar ZIP",
      viewAudiosButton: "Ver áudios",
      viewAudiosHint: "Abrir na aba 3 para ouvir capítulos individuais",
      empty: "Nenhuma conversão finalizada disponível ainda.",
      justNow: "agora mesmo",
      minutesAgo: (m: number) => `há ${m} min`,
      hoursAgo: (h: number) => `há ${h}h`,
      daysAgo: (d: number) => `há ${d} dia${d > 1 ? "s" : ""}`,
      stateLabels: {
        queued: "Na fila",
        running: "Convertendo",
        finished: "Concluído",
        failed: "Falhou",
        cancelling: "Cancelando",
        cancelled: "Cancelado",
        interrupted: "Interrompido",
      },
      completedAtLabel: (value: string) => `Concluído em ${value}`,
      durationLabel: (value: string) => `Tempo total: ${value}`,
      removeButton: "Remover",
    },
    hero: {
      badge: "Livro em áudio",
      title: "Transforme seu EPUB ou PDF em MP3 com poucos cliques",
      subtitle:
        "Envie o arquivo, escolha a voz preferida e deixe o serviço Python narrar a história para você ouvir onde quiser.",
      highlights: [
        {
          title: "Edge → XTTS → Piper",
          description:
            "Escolhemos automaticamente o motor mais estável para manter qualidade e velocidade.",
        },
        {
          title: "Multi-idioma real",
          description:
            "Detectamos mudanças de idioma no texto e alternamos a voz sem precisar configurar nada.",
        },
        {
          title: "Conversões retomáveis",
          description:
            "O cache inteligente retoma jobs interrompidos e evita refazer capítulos já prontos.",
        },
      ],
    },
    tabs: {
      setup: {
        label: "1. Preparar conversão",
        description: "Envie o livro e escolha voz, notas e capítulos.",
        panelTitle: "Envie seu livro",
        panelDescription: "Faça o upload e escolha como o áudio deve soar.",
        savedBatchTitle: (count: number) =>
          `📋 Fila salva com ${count} livro${count !== 1 ? "s" : ""} pendente${count !== 1 ? "s" : ""}`,
        savedBatchResume: "Retomar fila",
        savedBatchDismiss: "Descartar",
        savedBatchNeedsReupload: (count: number) =>
          `⚠️ ${count} livro${count !== 1 ? "s precisam" : " precisa"} ser reenviado${count !== 1 ? "s" : ""} (arquivo não pode ser salvo)`,
      },
      progress: {
        label: "2. Acompanhar andamento",
        description: "Veja o passo a passo enquanto o serviço Python trabalha.",
        panelTitle: "Status da conversão",
        panelDescription: "Aqui ficam as mensagens mais recentes.",
        activeBadge: "Convertendo agora",
        backButton: "← Voltar",
        viewDownloads: "Ver Downloads →",
      },
      downloads: {
        label: "3. Ouvir e baixar",
        description:
          "Os capítulos prontos aparecem aqui para download imediato.",
        panelTitle: "Seus arquivos MP3",
        panelDescription:
          "Baixe os capítulos convertidos ou inicie outra conversão.",
        footer: "",
        backButton: "← Voltar",
        followConversion: "Acompanhar conversão →",
      },
    },
    activeConversion: {
      title: "Conversão em andamento",
      currentLabel: "Livro em processamento",
      etaLabel: "Tempo estimado",
      queueHint:
        "Qualquer novo arquivo enviado aqui entra na fila logo após este livro terminar.",
      description:
        "Você pode continuar adicionando livros normalmente. Eles serão processados na sequência.",
      viewProgress: "Ver andamento",
      cancel: "Cancelar conversão",
      skip: "Pular para próximo",
      engineLabel: "Motor",
      voiceLabel: "Voz",
      languageLabel: "Idioma",
    },
    form: {
      fileLabel: "Arquivo do livro (EPUB ou PDF)",
      fileHint:
        "Selecione um ou mais arquivos do seu computador. Todos usarão as mesmas configurações abaixo.",
      fileQueueLabel: "Fila de livros",
      fileQueueEmpty:
        "Nenhum livro na fila. Adicione quantos quiser antes de converter.",
      fileQueueWithCurrent: (title: string) =>
        `“${title}” está sendo convertido. Novos livros entram logo depois.`,
      fileQueueCount: (count: number) =>
        count === 1 ? "1 livro" : `${count} livros`,
      fileQueueRemove: "Remover",
      fileQueueMoveUp: "Mover para cima",
      fileQueueMoveDown: "Mover para baixo",
      fileQueueReorderHint:
        "Arraste ou use as setas para alterar a ordem. Os livros serão convertidos de cima para baixo.",
      useSampleButton: "Usar livro de exemplo",
      addFolderButton: "Adicionar pasta inteira",
      engineLabel: "Como quer que a voz soe?",
      engineOptions: [
        {
          value: "edge",
          label: "Edge (padrão)",
          help: "Vozes de nuvem da Microsoft. Mais rápido (~70 chars/s). Multilíngue.",
        },
        {
          value: "piper",
          label: "Piper",
          help: "Modelos PT/EN incluídos. Offline, qualidade básica.",
        },
      ],
      engineDetails: {
        edge: {
          tagline:
            "A escolha mais versátil — vozes neurais na nuvem da Microsoft",
          quality: "Alta — entonação natural, respiração realista",
          speed: "~70 chars/s — o mais rápido de todos",
          requirements: "Conexão com a internet",
          bestVoice: "pt-BR-ThalitaMultilingualNeural",
          bestVoiceNote:
            "Thalita é multilíngue: troca de idioma automaticamente no mesmo texto. Para voz masculina, use AntonioNeural.",
          pros: [
            "Mais rápido de todos os motores",
            "Vozes naturais com entonação expressiva",
            "16+ vozes em pt-BR (femininas e masculinas)",
            "Multilíngue automático com Thalita",
            "Não precisa baixar nada",
          ],
          cons: [
            "Precisa de internet",
            "Pode sofrer rate-limiting em uso intenso",
            "Vozes são da Microsoft (não 100% open-source)",
          ],
          languages:
            "Todos (automático) — pt, en, es, fr, de, it, ja, zh e mais",
        },
        piper: {
          tagline: "Leve, offline e garantido — o fallback confiável",
          quality: "Básica — voz robótica mas inteligível",
          speed: "~25 chars/s — moderado",
          requirements: "Nenhum — funciona em qualquer máquina",
          bestVoice: "pt_BR-faber-medium.onnx",
          bestVoiceNote:
            "Faber é a melhor voz pt-BR disponível. Para inglês, Lessac-medium tem qualidade superior.",
          pros: [
            "100% offline — sem internet necessária",
            "Extremamente leve (~15 MB por modelo)",
            "Funciona em qualquer hardware",
            "Nunca falha — é o fallback final do sistema",
          ],
          cons: [
            "Qualidade de voz mais robótica",
            "Poucos modelos em português",
            "Sem expressividade emocional",
            "Um modelo por idioma (não multilíngue)",
          ],
          languages: "pt-BR, en-US, es, fr, de, it (um modelo por idioma)",
        },
      },
      autoEngineComparisonTitle: "Comparação rápida dos motores",
      autoEngineComparisonNote:
        "No modo automático, o sistema escolhe o melhor motor disponível com base no idioma e nos recursos da máquina.",
      comparisonHeaders: {
        engine: "Motor",
        quality: "Qualidade",
        speed: "Velocidade",
        languages: "Idiomas",
        needs: "Requisitos",
      },
      voicePreviewPlay: "Ouvir amostra",
      voicePreviewStop: "Parar",
      voicePreviewLoading: "Gerando amostra…",
      voicePreviewError: "Falha ao gerar amostra. Tente outra voz.",
      defaultVoiceLabel: "Voz padrão com suporte a vários idiomas",
      multilingualSupportLabel: "Suporte multilíngue",
      multilingualYes: "Sim, detecta automaticamente.",
      multilingualNo: "Não, escolha o idioma manualmente.",
      autoLanguageLabel: "Detecção automática de idioma ativada.",
      manualLanguageLabel: "Selecione o idioma para esta conversão.",
      voiceLabel: "Nome da voz (opcional)",
      voicePlaceholder: "Deixe vazio para usar a voz padrão",
      voiceHint:
        "Você pode escolher uma voz específica se souber o nome dela. Caso contrário, mantenha em branco.",
      voiceMultilingualHint:
        "Esta voz suporta múltiplos idiomas automaticamente.",
      voiceLoading: "Carregando vozes recomendadas…",
      voiceLoadFailed:
        "Não foi possível carregar a lista de vozes. Usando as sugestões padrão.",
      chaptersLabel: "Quais capítulos você quer ouvir? (opcional)",
      chaptersPlaceholder: "Ex.: 1,2 ou 3.1 (deixe em branco para todos)",
      chaptersHint:
        "Separe os números por vírgula. O app usa todos os capítulos se você deixar vazio.",
      fromChapterToEndLabel:
        "Converter do capítulo (inclusive) até o fim (opcional)",
      fromChapterToEndPlaceholder: "Ex.: 5.1",
      fromChapterToEndHint:
        "Use a mesma sintaxe do campo de capítulos. Deixe vazio para ignorar.",
      fromChapterToChapterLabel: "Converter intervalo de capítulos (opcional)",
      fromChapterToChapterPlaceholder: "Ex.: 5.1..7.3",
      fromChapterToChapterHint:
        "Informe início e fim com '..' (mesma sintaxe do campo de capítulos).",
      priorityLabel: "Quais capítulos devem ter prioridade? (opcional)",
      priorityPlaceholder: "Ex.: 1,4 ou Prólogo (sintaxe igual ao campo acima)",
      priorityHint:
        "Capítulos listados aqui são narrados primeiro, depois o restante segue na ordem original.",
      footnoteLegend: "Como tratar as notas de rodapé?",
      footnoteOptions: [
        {
          value: "inline",
          title: "Ler junto com a história",
          description:
            "As notas entram na mesma hora do texto. Ideal para quem não quer perder detalhes.",
        },
        {
          value: "chapter_end",
          title: "Ler depois do capítulo",
          description:
            "Guarda as notas para o final de cada capítulo. O áudio principal fica mais limpo.",
        },
        {
          value: "skip",
          title: "Não ler as notas",
          description:
            "Ignora notas de rodapé por completo. Use se elas não forem importantes para você.",
        },
      ],
      languageLabel: "Idioma do áudio",
      languagePlaceholder: "Selecione o idioma principal",
      languageHint:
        "Escolha o idioma quando o motor não fizer detecção automática.",
      languageNotRequired: "Este motor detecta o idioma sozinho.",
      languageAutoDetected:
        "O idioma será detectado automaticamente a partir do livro.",
      voiceAutoSelected:
        "A voz será selecionada automaticamente com base no idioma detectado.",
      voiceAutoOption: "Seleção automática por idioma",
      languageOptions: {
        auto: "Automático",
        pt: "Português (Brasil)",
        en: "Inglês (Estados Unidos)",
        es: "Espanhol (América Latina)",
        fr: "Francês",
        de: "Alemão",
      },
      availableLanguagesLabel: "Idiomas disponíveis",
      errorNoFile: "Selecione um arquivo EPUB ou PDF antes de enviar.",
      autoUploadHint:
        "Detectamos título e capa automaticamente ao escolher o arquivo. Esse upload é reaproveitado na conversão.",
      autoUploadPending: "Detectando capa e metadados…",
      autoUploadReady:
        "Metadados detectados. Você já pode converter sem reenviar o arquivo.",
      uploadingFile: "Enviando arquivo para detectar capa…",
      advancedSummary: "Opções avançadas",
      errorFileTooLarge: (limit: number) =>
        `Arquivo maior que ${limit} MB. Envie um EPUB/PDF menor para evitar falhas.`,
      submitIdle: "Converter agora",
      submitBusy: "Converter agora",
      estimatedDuration: (f: string) => `~${f}`,
      formattingCuesLabel: "Narrar formatação (aspas, itálico, negrito)",
      formattingCuesDescription:
        "Fala “entre aspas” e “fim das aspas”, “em negrito”, etc., usando o idioma do site.",
      formattingCuesOn: "Ativado",
      formattingCuesOff: "Desativado",
      characterVoicesLabel: "Vozes diferentes para narrador e personagens",
      characterVoicesDescription:
        "Trechos entre aspas ou em linhas começando com travessão são lidos com a voz dos personagens; o resto fica com a voz do narrador.",
      characterVoicesOn: "Ativado",
      characterVoicesOff: "Desativado",
      narratorVoiceLabel: "Voz do narrador",
      characterVoiceLabel: "Voz dos personagens",
      characterVoicesAutoOption: "Mesma voz selecionada acima",
      exportToIphoneLabel: "Enviar para iPhone (iCloud Drive)",
      exportToIphoneDescription:
        "Ao terminar, copia os MP3 para a pasta MP3AudioBookPlayer no iCloud Drive. Sincroniza automaticamente para o iPhone, sem cabo. macOS apenas.",
      exportToIphoneOn: "Ativado",
      exportToIphoneOff: "Desativado",
      noParallelLabel: "Desativar paralelismo (1 capítulo por vez)",
      noParallelDescription:
        "Útil para Edge online em redes instáveis; reduz travamentos e pode ser mais rápido.",
      noParallelOn: "Sequencial",
      noParallelOff: "Automático",
      multiEngineParallelLabel: "Múltiplos engines em paralelo",
      multiEngineParallelDescription:
        "Usa Edge e Piper simultaneamente em capítulos diferentes para máxima velocidade. Desligado por padrão — engines locais podem ter erros de detecção de idioma.",
      multiEngineParallelOn: "Ativado",
      multiEngineParallelOff: "Desativado",
      maxPerformanceLabel: "Velocidade máxima",
      maxPerformanceDescription:
        "Tenta usar o maior paralelismo e chunks mais longos (pode exigir mais CPU/RAM).",
      maxPerformanceOn: "Turbo ligado",
      maxPerformanceOff: "Balanceado",
      parallelSlotsLabel: "Capítulos em paralelo (opcional)",
      parallelSlotsPlaceholder: "Deixe vazio para automático",
      parallelSlotsHint:
        "Define quantos capítulos podem ser processados ao mesmo tempo.",
      chapterStallSecondsLabel: "Watchdog: travamento por capítulo (s)",
      chapterStallSecondsPlaceholder: "Ex.: 60",
      chapterStallSecondsHint:
        "Reinicia o capítulo se ficar sem progresso por esse tempo.",
      edgeNetworkTierLabel: "Edge: perfil de rede",
      edgeNetworkTierHint:
        "Força um perfil de rede para ajustar o Edge logo no início.",
      edgeNetworkTierAuto: "Auto",
      edgeNetworkTierSlow: "Lenta",
      edgeNetworkTierMedium: "Média",
      edgeNetworkTierFast: "Rápida",
      edgeNetworkTierUltra: "Ultra",
      engineTuningLegend: "Ajustes por engine",
      modelLabel: "Modelo (Piper) opcional",
      modelPlaceholder: "Ex.: tts_models/multilingual/multi-dataset/xtts_v2",
      modelHint:
        "Informe o ID do modelo ou caminho local no servidor (se aplicável).",
      edgeChunkCharsLabel: "Edge: tamanho do chunk (chars)",
      edgeChunkCharsPlaceholder: "Ex.: 24000",
      edgeChunkCharsHint:
        "Chunks maiores tendem a acelerar, mas podem falhar em redes instáveis.",
      edgeMaxSegmentSecondsLabel: "Edge: limite por segmento (s)",
      edgeMaxSegmentSecondsPlaceholder: "Ex.: 95",
      edgeMaxSegmentSecondsHint:
        "Limite de duração por segmento antes de dividir o texto.",
      edgeEnableParallelLabel: "Edge: paralelismo interno",
      edgeEnableParallelHint:
        "Ativa o processamento paralelo de segmentos dentro do capítulo.",
      edgeEnableParallelOn: "Ativado",
      edgeEnableParallelOff: "Desativado",
      edgeAutoTuneLabel: "Edge: auto-ajuste",
      edgeAutoTuneHint:
        "Ajusta chunk/tempo conforme rede e performance detectadas.",
      edgeAutoTuneOn: "Ativado",
      edgeAutoTuneOff: "Desativado",
      edgeStableModeLabel: "Edge: modo estável",
      edgeStableModeHint:
        "Força menos paralelismo e timeouts maiores para reduzir falhas em capítulos longos.",
      edgeStableModeOn: "Estável",
      edgeStableModeOff: "Normal",
      engineChainFallbackLabel: "Cascata de engines (legado)",
      engineChainFallbackHint:
        "Por padrão, permanecemos no Edge; falhas isoladas usam fallback por chunk. Ative para reabrir a cascata Edge → Piper quando o Edge estiver rate-limitado.",
      engineChainFallbackOn: "Cascata ativa",
      engineChainFallbackOff: "Só Edge",
      piperMaxProcsLabel: "Piper: processos simultâneos",
      piperMaxProcsPlaceholder: "Ex.: 3",
      piperMaxProcsHint: "Define o limite de processos Piper em paralelo.",
      audioLegend: "Saída de áudio",
      bitrateLabel: "Bitrate (kbps)",
      bitratePlaceholder: "Ex.: 8k",
      bitrateHint:
        "Valores menores geram arquivos menores (voz ainda fica ok).",
      sampleRateLabel: "Sample rate (Hz)",
      sampleRatePlaceholder: "Ex.: 16000",
      sampleRateHint:
        "16kHz é suficiente para voz; valores maiores aumentam tamanho.",
      channelsLabel: "Canais",
      channelsHint: "Mono é recomendado para audiobooks.",
      channelsMono: "Mono (1)",
      channelsStereo: "Estéreo (2)",
      processingLegend: "Processamento",
      verboseLabel: "Logs detalhados",
      verboseDescription: "Exibe saída detalhada das engines no painel.",
      verboseOn: "Ativado",
      verboseOff: "Reduzido",
      clearCacheLabel: "Limpar cache antes de converter",
      clearCacheDescription:
        "Remove textos/trechos em cache deste livro antes de iniciar.",
      clearCacheOn: "Limpar",
      clearCacheOff: "Manter",
      forceReprocessLabel: "Forçar reprocessamento",
      forceReprocessDescription: "Ignora arquivos já gerados e refaz tudo.",
      forceReprocessOn: "Forçar",
      forceReprocessOff: "Normal",
      filterChaptersLabel: "Filtrar capítulos curtos",
      filterChaptersDescription:
        "Remove trechos muito pequenos ao montar o índice.",
      filterChaptersOn: "Filtrar",
      filterChaptersOff: "Manter",
      languageDetectionLegend: "Detecção de idioma",
      languageDetectionLabel: "Detectar idioma no texto",
      languageDetectionDescription:
        "Marca trechos em outros idiomas automaticamente.",
      languageDetectionOn: "Ativado",
      languageDetectionOff: "Desativado",
      prioritizePrimaryLanguageLabel: "Priorizar idioma principal",
      prioritizePrimaryLanguageDescription:
        "Em ambiguidades, mantém o idioma principal do livro.",
      prioritizePrimaryLanguageOn: "Ativado",
      prioritizePrimaryLanguageOff: "Desativado",
      healthCheckLegend: "Healthcheck automático",
      healthCheckIntervalLabel: "Intervalo do healthcheck (s)",
      healthCheckIntervalPlaceholder: "Auto (30)",
      healthCheckIntervalHint:
        "Verifica lentidão/uso de recursos e ajusta o paralelismo.",
      healthCheckSlowEdgeCpsLabel: "Limiar Edge (chars/s)",
      healthCheckSlowEdgeCpsPlaceholder: "Auto (EDGE_MIN)",
      healthCheckSlowEdgeCpsHint: "Abaixo disso, ativa modo seguro do Edge.",
      healthCheckSlowCpsLabel: "Limiar outros motores (chars/s)",
      healthCheckSlowCpsPlaceholder: "Auto (30)",
      healthCheckSlowCpsHint:
        "Abaixo disso, reduz paralelismo para estabilizar.",
      healthCheckHighCpuLabel: "CPU alta (%)",
      healthCheckHighCpuPlaceholder: "Auto (85)",
      healthCheckHighCpuHint: "Acima disso, reduz paralelismo.",
      healthCheckHighMemLabel: "Memória alta (%)",
      healthCheckHighMemPlaceholder: "Auto (85)",
      healthCheckHighMemHint: "Acima disso, reduz paralelismo.",
      healthCheckOkCpuLabel: "CPU ok (%)",
      healthCheckOkCpuPlaceholder: "Auto (75)",
      healthCheckOkCpuHint: "Abaixo disso, pode aumentar paralelismo.",
      healthCheckOkMemLabel: "Memória ok (%)",
      healthCheckOkMemPlaceholder: "Auto (80)",
      healthCheckOkMemHint: "Abaixo disso, pode aumentar paralelismo.",
      healthCheckSlowStreakLabel: "Lentidão consecutiva",
      healthCheckSlowStreakPlaceholder: "Auto (2)",
      healthCheckSlowStreakHint:
        "Quantidade de checks lentos antes de ajustar.",
      sectionsLabel: "Seções adicionais (opcional)",
      sectionsPlaceholder: "Ex.: 2.1, 2.2 ou epílogo",
      sectionsHint:
        "Use para selecionar subseções ou títulos específicos junto ao campo acima.",
    },
    status: {
      phases: {
        idle: "Pronto para começar",
        submitting: "Enviando arquivo…",
        polling: "Lendo e convertendo…",
        success: "Tudo pronto!",
        error: "Ops, algo deu errado",
        cancelling: "Cancelando…",
        cancelled: "Cancelado",
      },
      jobLabel: (jobId: string) => `Código do pedido: ${jobId}`,
      placeholder: "Envie um arquivo para acompanhar o passo a passo aqui.",
      errorPrefix: "Detalhes: {message}",
      toggleShow: "Mostrar saída do terminal",
      toggleHide: "Ocultar saída do terminal",
      etaLabel: "Tempo estimado",
      etaCalculating: "calculando…",
      etaSoon: "quase pronto",
      etaDone: "concluído",
      cancelButton: "Parar conversão",
      cancelButtonPending: "Cancelando…",
      skipButton: "Pular para próximo",
      progressLabel: "Progresso geral",
      summaryTitle: "Resumo da execução",
      summaryLanguage: "Idioma detectado",
      summaryChapters: "Capítulos totais",
      summaryCurrent: "Capítulo em andamento",
      summaryHint: "Status em tempo real",
      summaryProgress: "Progresso",
      summaryParallel: "Capítulos em paralelo",
      chapterProgressTitle: "Progresso por capítulo",
      expandAllChapters: "Expandir tudo",
      collapseAllChapters: "Recolher tudo",
      showAllText: "Mostrar todo texto",
      hideAllText: "Ocultar texto",
      scrollToTop: "Ir ao topo",
      downloadFullText: "Baixar texto completo",
      searchPlaceholder: "Buscar no texto completo…",
      searchCount: (count: number) =>
        count === 1 ? "1 ocorrência" : `${count} ocorrências`,
      searchPrev: "Anterior",
      searchNext: "Próxima",
      readerTitle: "Leitor sincronizado",
      readerReadButton: "Ler livro",
      readerUnavailable:
        "Não foi possível carregar o texto do livro. Tente novamente em instantes.",
      readerStillExtracting:
        "Ainda extraindo o texto do livro… isto pode levar alguns segundos.",
      readerExtractionFailed:
        "Não foi possível extrair capítulos deste arquivo. Verifique se o EPUB/PDF é válido.",
      readerLoading: "Carregando texto do EPUB/PDF…",
      readerEmpty: "Selecione um capítulo para começar a ler.",
      readerOpen: "Abrir leitor",
      readerClose: "Fechar leitor",
      readerOpenPopup: "Abrir em popup",
      readerExitPopup: "Sair do popup",
      readerChaptersTitle: "Capítulos",
      readerPageLabel: (current: number, total: number) =>
        `Página ${current} de ${total}`,
      readerPrevPage: "Página anterior",
      readerNextPage: "Próxima página",
      readerFollowAudioLabel: "Seguir áudio",
      readerFollowAudioOn: "Seguindo a narração",
      readerFollowAudioOff: "Leitura manual",
      readerThemeLabel: "Tema",
      readerThemePaper: "Papel",
      readerThemeMist: "Bruma",
      readerThemeInk: "Tinta",
      readerFontSizeLabel: "Tamanho da fonte",
      readerFontFamilyLabel: "Fonte",
      readerFontFamilySerif: "Serifa",
      readerFontFamilySans: "Sem serifa",
      readerLineHeightLabel: "Espaçamento",
      readerWidthLabel: "Largura da coluna",
      readerNowReading: "Trecho em leitura",
      readerWaitingSegment: "Aguardando próximo segmento",
      readerPlaying: "Reproduzindo",
      readerPaused: "Pausado",
      readerSegmentLabel: (index: number) => `Segmento ${index}`,
      readerChapterCount: (count: number) =>
        count === 1 ? "capítulo" : "capítulos",
      readerAudioOnChapter: (index: number) => `Áudio no cap. ${index}`,
      readerRetryLoad: "Tentar carregar novamente",
      uiHealthTitle: "Saúde da interface",
      uiHealthSubtitle: (count: number) =>
        count === 1
          ? "1 problema recente detectado"
          : `${count} problemas recentes detectados`,
      uiHealthClear: "Limpar avisos",
      uiHealthDismiss: "Dispensar aviso",
      chapterStatuses: {
        pending: "Na fila",
        processing: "Convertendo",
        completed: "Concluído",
        skipped: "Ignorado",
        failed: "Falhou",
        cancelled: "Cancelado",
        retrying: "Tentando novamente",
      },
      chapterCompletedIn: (value: string) => `Concluído em ${value}`,
      chapterGoToCurrent: "Ver atual",
      chapterGoToCurrentTitle: "Ir para o capítulo atual",
      chapterFullAudio: "Capítulo completo:",
      chapterSegmentsTitle: "Segmentos do capítulo",
      chapterSegmentCount: (count: number) =>
        count <= 0 ? "sem segmentos" : `${count} segmentos`,
      chapterSegmentsNone: "Nenhum segmento disponível",
      chapterSegmentsWaiting: "Aguardando segmentos...",
      chapterSegmentsLoading: "Carregando segmentos...",
      chapterSegmentTitle: (index: number) => `Segmento ${index}`,
      chapterSegmentShowText: "Mostrar texto",
      chapterSegmentHideText: "Ocultar texto",
      chapterSegmentText: "Texto",
      chapterSegmentsEmpty: "Nenhum segmento disponível ainda.",
      chapterAudioUnsupported:
        "Seu navegador não oferece suporte à reprodução de áudio.",
      chapterEngineLabel: (engine: string) => `Motor: ${engine.toUpperCase()}`,
      bookFallbackTitle: "Livro carregado",
      bookFallbackAuthor: "Autor desconhecido",
      uploadingFiles: "Enviando livros…",
      errorCategoryHints: {
        rate_limit:
          "Limite de requisições atingido. Tente novamente em alguns minutos.",
        timeout:
          "A conversão demorou mais do que o esperado. Tente um engine diferente.",
        network: "Falha de rede. Verifique sua conexão e tente novamente.",
        engine_unavailable:
          "Nenhum engine TTS disponível. Verifique os logs do servidor.",
        audio_truncation:
          "Áudio gerado mais curto que o esperado. Tente diminuir o capítulo.",
        incomplete_segments:
          "Segmentos de áudio incompletos. O Edge-TTS pode estar sobrecarregado.",
        invalid_audio: "Arquivo de áudio inválido gerado. Tente outro engine.",
        cancelled: "Conversão cancelada pelo usuário.",
        file_not_found: "Arquivo não encontrado. Faça o upload novamente.",
        auth: "Erro de autenticação com o serviço TTS.",
      },
      ttsEngineLabel: "Motor TTS",
      speedLabel: "Velocidade",
      terminalLogLabel: "Log do Terminal",
      coverPhaseSubmitting: "Arquivo enviado",
      coverPhasePolling: "Lendo e convertendo",
      coverPhaseSuccess: "Conversão concluída",
      coverPhaseError: "Conversão interrompida",
      coverPhaseDefault: "Livro selecionado",
      cachedJobsTitle: "Conversões Interrompidas",
      cachedJobsClose: "Fechar aviso",
      cachedJobsSingular:
        "Encontramos 1 conversão interrompida. Deseja retomá-la?",
      cachedJobsPlural: (count: number) =>
        `Encontramos ${count} conversões interrompidas. Deseja retomar alguma?`,
      cachedJobsResume: "Retomar",
      cachedJobsRemove: (fileName: string) => `Remover ${fileName}`,
      cachedJobsJustNow: "agora mesmo",
      cachedJobsDaysAgo: (days: number) =>
        `${days} ${days === 1 ? "dia" : "dias"} atrás`,
      cachedJobsHoursAgo: (hours: number) =>
        `${hours} ${hours === 1 ? "hora" : "horas"} atrás`,
      cachedJobsMinutesAgo: (minutes: number) =>
        `${minutes} ${minutes === 1 ? "minuto" : "minutos"} atrás`,
    },
    downloads: {
      placeholder:
        "Assim que a conversão terminar, os áudios ficam disponíveis aqui para ouvir ou baixar.",
      noDownloadsAfterSuccess:
        "Conversão concluída, mas os arquivos não puderam ser carregados. Verifique as conversões recentes ou inicie uma nova.",
      resetWithDownloads: "Começar uma nova conversão",
      resetWithoutDownloads: "Limpar tudo",
      audioNotSupported: "Seu navegador não suporta reprodução de áudio.",
      downloadChapter: "⬇ Baixar MP3",
      downloadZip: "Baixar Audiolivro Completo (ZIP)",
      downloadZipHint: (count: number) =>
        `Contém ${count} ${count === 1 ? "capítulo" : "capítulos"} em MP3`,
      orIndividual: "Ou baixe/ouça os capítulos individualmente",
      downloadLog: "Baixar conversion.log",
      viewLog: "Ver conversion.log",
      hideLog: "Ocultar conversion.log",
      logLoading: "Carregando conversion.log…",
      logError: (message: string) =>
        `Não foi possível carregar conversion.log (${message}).`,
      viewingJobTitle: (title: string) => `Ouvindo capítulos de “${title}”`,
      viewingJobSubtitle:
        "Esses arquivos vêm de uma conversão finalizada. Você pode voltar para os downloads atuais quando quiser.",
      viewingJobBackToCurrent: "Ver downloads atuais",
      readyListTitle: "Livros prontos para download",
      readyListSubtitle:
        "Inclui títulos finalizados nesta fila e em sessões anteriores.",
      readyListAction: "Abrir downloads",
      readyListDownloadAll: "Baixar todos (ZIP)",
      readyListDownloadAllHint: "Abre o ZIP de cada livro em novas abas.",
      readyListItem: (count: number) =>
        count === 1 ? "1 capítulo pronto" : `${count} capítulos prontos`,
      readyListAriaLabel: "Histórico de audiolivros disponíveis",
      readyListTagCurrent: "Sessão atual",
      readyListTagPast: "Sessões anteriores",
      removeButton: "Remover",
      readyNotificationTitle: "Audiobook pronto",
      readyNotificationBody: (title: string) =>
        `“${title}” acabou de terminar.`,
      readyNotificationBodyFallback: "Um livro acabou de ser convertido.",
      shareTitle: "Compartilhe seu audiolivro",
      shareSubtitle: (book: string) =>
        `Envie “${book}” para amigos ou salve o link para ouvir depois.`,
      shareWhatsapp: "Enviar no WhatsApp",
      shareCopyLink: "Copiar link",
      shareCopied: "Link copiado!",
      shareCopyError: "Não foi possível copiar. Tente manualmente.",
      shareNative: "Compartilhar…",
      shareNativeUnavailable:
        "Seu navegador não abriu o menu de compartilhamento. Use copiar link.",
      shareUnavailable:
        "O link ficará disponível assim que houver um arquivo para baixar.",
      shareMessage: (book: string) =>
        `Terminei de converter “${book}” em audiobook com o EPUB to MP3. Ouça aqui:`,
      readyListCompletedAt: (value: string) => `Concluído em ${value}`,
      readyListDuration: (value: string) => `Tempo total: ${value}`,
      durationHours: (value: number) => `${value}h`,
      durationMinutes: (value: number) => `${value}min`,
      durationSeconds: (value: number) => `${value}s`,
    },
    layout: {
      footer: "",
      closeNotification: "Fechar notificação",
      updateAvailable: (version: string) =>
        `Atualização v${version} disponível`,
      updateInstall: "Instalar e reiniciar",
      updateInstalling: "Instalando...",
      updateDismiss: "Dispensar",
      updateInstallError: "Falha ao instalar a atualização. Tente novamente.",
      restartTitle: "Reiniciar backend Python",
      restartDescription:
        "Interrompe todas as conversões em andamento e limpa a fila atual.",
      restartButton: "Reiniciar backend",
      restartProgress: "Reiniciando…",
      restartConfirm:
        "Reiniciar agora vai interromper todas as conversões em andamento e limpar a fila. Deseja continuar?",
      restartConfirmYes: "Reiniciar",
      restartConfirmNo: "Cancelar",
      restartKeepCacheTitle: "Cache de capítulos",
      restartKeepCacheConfirm:
        "Deseja manter o cache local (capítulos já processados)?",
      restartKeepCacheYes: "Manter",
      restartKeepCacheNo: "Não manter",
      restartKeepFinishedTitle: "Arquivos concluídos",
      restartKeepFinishedConfirm:
        "Deseja manter as conversões finalizadas e os arquivos já gerados?",
      restartKeepFinishedYes: "Manter",
      restartKeepFinishedNo: "Não manter",
      restartNotifyTitle: "Reinicialização solicitada",
      restartNotifyBody:
        "Servidor reiniciando. Aguarde alguns segundos e recarregue esta página.",
      restartErrorBody:
        "Falha ao reiniciar automaticamente. Reinicie o backend manualmente.",
      helpToggle: "Ajuda & Sistema",
      helpTitle: "Ajuda e monitoramento",
      helpClose: "Fechar painel",
      statsTitle: "Monitoramento do sistema",
      statsLoading: "Coletando métricas…",
      statsUptime: "Uptime",
      statsCpu: "CPU",
      statsMemory: "Memória",
      statsQueue: "Fila",
      statsRunning: "Em execução",
      statsWorkers: "Workers",
      statsRecommendation: "Sugestão",
      statsGpu: "GPUs",
      statsError:
        "Não foi possível carregar as métricas. Verifique se o backend está atualizado.",
      statsOffline: "Servidor indisponível. Verifique o backend.",
      statsLastUpdated: (value: string) => `Atualizado ${value}`,
      statsRetrying: (value: string) => `Nova tentativa em ${value}`,
      statsTarget: "Alvo",
      statsGpuUsage: "Uso",
      statsGpuVram: "VRAM",
      statsGpuTemp: "Temp",
      tauriEngineWaiting: "Aguardando o motor de conversão iniciar…",
      tauriEngineErrorTitle: "Erro no motor de conversão",
      tauriEngineRebuild: "Reconstrua o sidecar:",
      telemetryTitle: "Telemetria",
      telemetryDescription:
        "Taxa de síntese TTS por engine, com base em amostras registradas.",
      telemetryRefresh: "Atualizar",
      telemetryRefreshing: "Atualizando…",
      telemetryErrorGeneric: "Falha ao carregar telemetria.",
      telemetryEmptyState:
        "Sem amostras de telemetria ainda — rode uma conversão para popular.",
      telemetryEngineHeader: "Engine",
      telemetrySamplesHeader: "Amostras",
      telemetryAvgHeader: "Média c/s",
      telemetryMinHeader: "Mín c/s",
      telemetryMaxHeader: "Máx c/s",
      telemetryRankedLabel: "Mais rápido → mais lento",
      telemetryTimelineTitle: "Capítulos recentes",
      telemetryTimelineEmpty: "Sem amostras recentes.",
      telemetryTimelineLatest: "Mais recentes primeiro",
      telemetryTotalSamples: (count: number) => `${count} amostras totais`,
      telemetryUpdatedAt: (iso: string) =>
        `Atualizado ${new Date(iso).toLocaleTimeString()}`,
    },
    flow: {
      startUpload: "Enviando arquivo para o servidor…",
      startReuse: "Preparando conversão com o arquivo já enviado…",
      jobCreated: (jobId: string) =>
        `Pedido ${jobId} recebido. Aguardando narração…`,
      resuming: "🔄 Retomando conversão interrompida…",
      loadingCache: "📦 Recuperando dados desta conversão...",
      completion: (count: number) =>
        `Conversão finalizada com ${count} arquivos de áudio.`,
      failure: (message: string) => `Pedido com erro: ${message}`,
      error: (message: string) => `Erro: ${message}`,
      defaultFailure: "A conversão falhou",
      defaultError: "Erro inesperado",
      cancelRequested: "🛑 Cancelamento solicitado. Concluindo passo atual…",
      cancelled: "Pedido cancelado pelo usuário.",
      skipped: "Livro atual ignorado, continuando com a fila.",
      cancelFailed: (message: string) =>
        `Não foi possível cancelar: ${message || "tente novamente"}`,
      skipConfirm: "Deseja pular este livro e continuar com o próximo da fila?",
      backendOffline: "Servidor de conversão indisponível",
      backendOfflineDetails:
        "Não foi possível contatar a API. Inicie o backend local (`python -m uvicorn python_app.server:app --reload --port 8000`) ou use `python app.py` (porta 7860) e configure VITE_API_BASE para essa porta.",
      backendConnecting: "Conectando ao servidor de conversão…",
      backendOfflineBanner:
        "Servidor Python não está respondendo. Inicie o backend local (porta 8000) ou use `python app.py` na porta 7860 e ajuste VITE_API_BASE. Depois recarregue esta página.",
      cachedRestoredSuccess:
        "Restaurado do cache local. Os downloads podem estar indisponíveis se o servidor foi reiniciado.",
      cancelConfirm:
        "Cancelar agora interrompe a conversão atual e remove os arquivos gerados. Deseja continuar?",
      batchPosition: (index: number, total: number) =>
        `📚 Livro ${index}/${total}`,
      batchCancelled: (remaining: number) =>
        remaining === 1
          ? "Fila interrompida. 1 livro ainda não foi convertido."
          : `Fila interrompida. ${remaining} livros ainda não foram convertidos.`,
      notificationErrorTitle: "Conversão falhou",
      notificationErrorBody:
        "Ocorreu um erro. Verifique o log para mais detalhes.",
      notificationCancelTitle: "Conversão cancelada",
      notificationCancelBody:
        "Conversão cancelada e removida. Você pode iniciar uma nova conversão quando quiser.",
    },
    queue: {
      title: "Adicionar livros enquanto converte",
      subtitle:
        "Os arquivos abaixo usam as mesmas configurações do passo 1 e entram na fila assim que o livro atual terminar.",
      inputLabel: "Escolha EPUB/PDF adicionais",
      hint: "Você pode continuar acompanhando passo 2 enquanto novos livros aguardam automaticamente.",
      addFolderButton: "Escolher pasta",
      success: (count: number) =>
        count === 1
          ? "1 livro adicionado à fila."
          : `${count} livros adicionados à fila.`,
      errorFallback: "Não foi possível adicionar à fila. Tente novamente.",
      phaseActive: "Convertendo",
      phaseSuccess: "Pronto para próxima fila",
      displayCurrentLabel: "Convertendo agora",
      displayQueueLabel: (count: number) =>
        `Na fila: ${count} ${count === 1 ? "livro" : "livros"}`,
      displayMoreLabel: (count: number) =>
        `+ ${count} ${count === 1 ? "outro" : "outros"}`,
      displayResumeButton: "▶ Retomar fila",
      displayClearButton: "Limpar fila",
      displayPausedBadge: "Pausada",
      displayShowLess: "Mostrar menos",
      displayMoveUp: "Mover para cima",
      displayMoveDown: "Mover para baixo",
    },
  },
  en: {
    locale: "en",
    topBar: {
      ariaLabel: "Theme and language preferences",
      themeLabel: "Theme",
      themeLight: "Light",
      themeDark: "Dark",
      themeAuto: "Auto",
      localeLabel: "Language",
      localeEnglish: "English",
      localePortuguese: "Portuguese",
      localeAuto: "Auto",
    },
    resumableJobs: {
      title: "Resume pending conversions",
      subtitle:
        "Pick up requests with cached chapters without uploading again.",
      empty: "No conversions waiting to resume.",
      loading: "Loading pending conversions...",
      resumeButton: "Resume now",
      removeButton: "Remove",
      toggleMore: (expanded: boolean) => (expanded ? "Show less" : "View all"),
      justNow: "just now",
      minutesAgo: (m: number) => `${m} min ago`,
      hoursAgo: (h: number) => `${h}h ago`,
      daysAgo: (d: number) => `${d} day${d > 1 ? "s" : ""} ago`,
      engineLabel: (value: string) => `Engine: ${value}`,
      voiceLabel: (value: string) => `Voice: ${value}`,
      languageLabel: (value: string) => `Language: ${value}`,
    },
    recentJobs: {
      title: "⚡ Recent conversions",
      subtitle:
        "Pick up where you left off or download any finished job stored on the server.",
      resumeButton: "Resume",
      downloadButton: "Download ZIP",
      viewAudiosButton: "Listen",
      viewAudiosHint: "Jump to tab 3 and play individual chapters",
      empty: "No finished conversions yet.",
      justNow: "just now",
      minutesAgo: (m: number) => `${m} min ago`,
      hoursAgo: (h: number) => `${h}h ago`,
      daysAgo: (d: number) => `${d} day${d > 1 ? "s" : ""} ago`,
      stateLabels: {
        queued: "Queued",
        running: "Converting",
        finished: "Finished",
        failed: "Failed",
        cancelling: "Cancelling",
        cancelled: "Cancelled",
        interrupted: "Interrupted",
      },
      completedAtLabel: (value: string) => `Finished on ${value}`,
      durationLabel: (value: string) => `Total time: ${value}`,
      removeButton: "Remove",
    },
    hero: {
      badge: "Audio book",
      title: "Turn your EPUB or PDF into MP3 in just a few clicks",
      subtitle:
        "Upload the file, pick a voice you like, and let the Python service narrate the story so you can listen anywhere.",
      highlights: [
        {
          title: "Edge → XTTS → Piper",
          description:
            "Automatically picks the most reliable engine to keep quality and speed high.",
        },
        {
          title: "True multilingual",
          description:
            "Detects language changes per chapter and switches voices with zero configuration.",
        },
        {
          title: "Resume conversions",
          description:
            "Smart caching resumes interrupted jobs and skips chapters already rendered.",
        },
      ],
    },
    tabs: {
      setup: {
        label: "1. Prepare conversion",
        description:
          "Upload the book and choose voice, footnotes, and chapters.",
        panelTitle: "Upload your book",
        panelDescription:
          "Send the file and define how the audio should sound.",
        savedBatchTitle: (count: number) =>
          `📋 Saved queue with ${count} book${count !== 1 ? "s" : ""} pending`,
        savedBatchResume: "Resume queue",
        savedBatchDismiss: "Dismiss",
        savedBatchNeedsReupload: (count: number) =>
          `⚠️ ${count} book${count !== 1 ? "s need" : " needs"} to be re-uploaded (file cannot be saved)`,
      },
      progress: {
        label: "2. Track progress",
        description: "Follow each step while the Python service works.",
        panelTitle: "Conversion status",
        panelDescription: "The latest messages show up here.",
        activeBadge: "Running",
        backButton: "← Back",
        viewDownloads: "View Downloads →",
      },
      downloads: {
        label: "3. Listen & download",
        description: "Finished chapters become available for instant download.",
        panelTitle: "Your MP3 files",
        panelDescription: "Download the chapters or start another conversion.",
        footer: "",
        backButton: "← Back",
        followConversion: "Follow conversion →",
      },
    },
    activeConversion: {
      title: "Conversion in progress",
      currentLabel: "Currently processing",
      etaLabel: "Estimated time",
      queueHint: "Any new upload here is queued right after this book is done.",
      description:
        "Feel free to keep adding titles—everything waits in the queue.",
      viewProgress: "View progress",
      cancel: "Cancel conversion",
      skip: "Skip to next",
      engineLabel: "Engine",
      voiceLabel: "Voice",
      languageLabel: "Language",
    },
    form: {
      fileLabel: "Book file (EPUB or PDF)",
      fileHint:
        "Select one or more files from your computer. Every book will reuse the same settings below.",
      fileQueueLabel: "Queued books",
      fileQueueEmpty:
        "No books queued yet. Add as many as you like before converting.",
      fileQueueWithCurrent: (title: string) =>
        `"${title}" is converting now. New uploads will start right after.`,
      fileQueueCount: (count: number) =>
        count === 1 ? "1 book" : `${count} books`,
      fileQueueRemove: "Remove",
      fileQueueMoveUp: "Move up",
      fileQueueMoveDown: "Move down",
      fileQueueReorderHint:
        "Drag or use the arrows to reorder. Books convert from top to bottom.",
      useSampleButton: "Use sample book",
      addFolderButton: "Add entire folder",
      engineLabel: "How should the voice sound?",
      engineOptions: [
        {
          value: "edge",
          label: "Edge (default)",
          help: "Microsoft cloud voices. Fastest (~70 chars/s). Multilingual.",
        },
        {
          value: "piper",
          label: "Piper",
          help: "Bundled PT/EN voices. Offline, basic quality.",
        },
      ],
      engineDetails: {
        edge: {
          tagline: "The most versatile pick — Microsoft neural cloud voices",
          quality: "High — natural intonation, realistic breathing",
          speed: "~70 chars/s — the fastest of all",
          requirements: "Internet connection",
          bestVoice: "pt-BR-ThalitaMultilingualNeural",
          bestVoiceNote:
            "Thalita is multilingual: switches languages automatically within the same text. For a male voice, use AntonioNeural.",
          pros: [
            "Fastest engine available",
            "Natural voices with expressive intonation",
            "16+ pt-BR voices (male and female)",
            "Automatic multilingual with Thalita",
            "No downloads needed",
          ],
          cons: [
            "Requires internet",
            "May hit rate-limiting under heavy use",
            "Microsoft voices (not fully open-source)",
          ],
          languages:
            "All (automatic) — pt, en, es, fr, de, it, ja, zh and more",
        },
        piper: {
          tagline: "Lightweight, offline, and reliable — the trusty fallback",
          quality: "Basic — robotic but intelligible voice",
          speed: "~25 chars/s — moderate",
          requirements: "None — works on any machine",
          bestVoice: "pt_BR-faber-medium.onnx",
          bestVoiceNote:
            "Faber is the best available pt-BR voice. For English, Lessac-medium offers superior quality.",
          pros: [
            "100% offline — no internet needed",
            "Extremely lightweight (~15 MB per model)",
            "Works on any hardware",
            "Never fails — the system's final fallback",
          ],
          cons: [
            "More robotic voice quality",
            "Few Portuguese models",
            "No emotional expressiveness",
            "One model per language (not multilingual)",
          ],
          languages: "pt-BR, en-US, es, fr, de, it (one model per language)",
        },
      },
      autoEngineComparisonTitle: "Quick engine comparison",
      autoEngineComparisonNote:
        "In automatic mode, the system picks the best available engine based on language and machine resources.",
      comparisonHeaders: {
        engine: "Engine",
        quality: "Quality",
        speed: "Speed",
        languages: "Languages",
        needs: "Requirements",
      },
      voicePreviewPlay: "Listen to sample",
      voicePreviewStop: "Stop",
      voicePreviewLoading: "Generating sample…",
      voicePreviewError: "Failed to generate sample. Try another voice.",
      defaultVoiceLabel: "Default voice with multi-language support",
      multilingualSupportLabel: "Multilingual support",
      multilingualYes: "Yes, language is detected automatically.",
      multilingualNo: "No, pick the language manually.",
      autoLanguageLabel: "Automatic language detection enabled.",
      manualLanguageLabel: "Select the language for this conversion.",
      voiceLabel: "Voice name (optional)",
      voicePlaceholder: "Leave blank to use the default voice",
      voiceHint:
        "Type a specific voice name if you know it. Otherwise keep it blank.",
      voiceMultilingualHint:
        "This voice supports multiple languages automatically.",
      voiceLoading: "Loading recommended voices…",
      voiceLoadFailed:
        "Unable to fetch the voice list. Using the built-in suggestions.",
      chaptersLabel: "Which chapters do you want? (optional)",
      chaptersPlaceholder: "Example: 1,2 or 3.1 (leave blank for all)",
      chaptersHint:
        "Separate numbers with commas. All chapters are used if left blank.",
      fromChapterToEndLabel: "Convert from this chapter to the end (optional)",
      fromChapterToEndPlaceholder: "Example: 5.1",
      fromChapterToEndHint:
        "Uses the same syntax as the chapters field. Leave blank to ignore.",
      fromChapterToChapterLabel: "Convert a chapter range (optional)",
      fromChapterToChapterPlaceholder: "Example: 5.1..7.3",
      fromChapterToChapterHint:
        "Provide start and end with '..' (same syntax as chapters).",
      priorityLabel: "Prioritize specific chapters? (optional)",
      priorityPlaceholder: "Example: 1,4 or Prologue (same syntax as above)",
      priorityHint:
        "Chapters listed here will be rendered first, then the remaining ones follow the original order.",
      footnoteLegend: "How should we read footnotes?",
      footnoteOptions: [
        {
          value: "inline",
          title: "Read with the story",
          description: "Keep footnotes in place so you never miss details.",
        },
        {
          value: "chapter_end",
          title: "Read after each chapter",
          description:
            "Collect footnotes at the end. The main audio stays cleaner.",
        },
        {
          value: "skip",
          title: "Skip footnotes",
          description:
            "Ignore footnotes completely if they are not important to you.",
        },
      ],
      languageLabel: "Audio language",
      languagePlaceholder: "Choose the primary language",
      languageHint:
        "Select the language whenever the engine cannot switch automatically.",
      languageNotRequired: "This engine detects the language automatically.",
      languageAutoDetected:
        "Language will be automatically detected from the book.",
      voiceAutoSelected:
        "Voice will be automatically selected based on detected language.",
      voiceAutoOption: "Automatic selection based on language",
      languageOptions: {
        auto: "Automatic",
        pt: "Portuguese (Brazil)",
        en: "English (United States)",
        es: "Spanish (Latin America)",
        fr: "French",
        de: "German",
      },
      availableLanguagesLabel: "Available languages",
      errorNoFile: "Choose an EPUB or PDF file before converting.",
      autoUploadHint:
        "We extract title and cover automatically once you pick a file. That upload is reused during conversion.",
      autoUploadPending: "Extracting cover and metadata…",
      autoUploadReady: "Metadata detected. Conversion will reuse this upload.",
      uploadingFile: "Uploading file to detect cover…",
      advancedSummary: "Advanced options",
      errorFileTooLarge: (limit: number) =>
        `File exceeds the ${limit} MB limit. Please upload a smaller EPUB/PDF.`,
      submitIdle: "Convert now",
      submitBusy: "Convert now",
      estimatedDuration: (f: string) => `~${f}`,
      formattingCuesLabel: "Narrate formatting (quotes, italics, bold)",
      formattingCuesDescription:
        "Says “quote”, “end quote”, and other cues using the site language.",
      formattingCuesOn: "Enabled",
      formattingCuesOff: "Disabled",
      characterVoicesLabel: "Different voices for narrator and characters",
      characterVoicesDescription:
        "Quoted spans and em-dash dialogue lines are read with the character voice; everything else uses the narrator voice.",
      characterVoicesOn: "Enabled",
      characterVoicesOff: "Disabled",
      narratorVoiceLabel: "Narrator voice",
      characterVoiceLabel: "Character voice",
      characterVoicesAutoOption: "Same voice selected above",
      exportToIphoneLabel: "Send to iPhone (iCloud Drive)",
      exportToIphoneDescription:
        "When finished, copies the MP3s into the MP3AudioBookPlayer iCloud Drive folder. Syncs automatically to the iPhone, no cable. macOS only.",
      exportToIphoneOn: "Enabled",
      exportToIphoneOff: "Disabled",
      noParallelLabel: "Disable parallelism (1 chapter at a time)",
      noParallelDescription:
        "Useful for online Edge voices on unstable networks; reduces stalls and may be faster.",
      noParallelOn: "Sequential",
      noParallelOff: "Automatic",
      multiEngineParallelLabel: "Multi-engine parallel",
      multiEngineParallelDescription:
        "Runs Edge and Piper simultaneously on different chapters for maximum throughput. Off by default — local engines may misdetect language.",
      multiEngineParallelOn: "Enabled",
      multiEngineParallelOff: "Disabled",
      maxPerformanceLabel: "Maximum speed",
      maxPerformanceDescription:
        "Pushes higher parallelism and longer chunks (may use more CPU/RAM).",
      maxPerformanceOn: "Turbo on",
      maxPerformanceOff: "Balanced",
      parallelSlotsLabel: "Parallel chapters (optional)",
      parallelSlotsPlaceholder: "Leave blank for automatic",
      parallelSlotsHint: "Sets how many chapters can run in parallel.",
      chapterStallSecondsLabel: "Watchdog: chapter stall (s)",
      chapterStallSecondsPlaceholder: "e.g., 60",
      chapterStallSecondsHint:
        "Restarts the chapter if no progress happens for this long.",
      edgeNetworkTierLabel: "Edge: network profile",
      edgeNetworkTierHint:
        "Forces a network profile so Edge adjusts settings early.",
      edgeNetworkTierAuto: "Auto",
      edgeNetworkTierSlow: "Slow",
      edgeNetworkTierMedium: "Medium",
      edgeNetworkTierFast: "Fast",
      edgeNetworkTierUltra: "Ultra",
      engineTuningLegend: "Engine tuning",
      modelLabel: "Model (Piper) optional",
      modelPlaceholder: "e.g., tts_models/multilingual/multi-dataset/xtts_v2",
      modelHint: "Provide the model ID or a server path when applicable.",
      edgeChunkCharsLabel: "Edge: chunk size (chars)",
      edgeChunkCharsPlaceholder: "e.g., 24000",
      edgeChunkCharsHint:
        "Larger chunks are faster but can fail on unstable networks.",
      edgeMaxSegmentSecondsLabel: "Edge: segment limit (s)",
      edgeMaxSegmentSecondsPlaceholder: "e.g., 95",
      edgeMaxSegmentSecondsHint: "Max duration per segment before splitting.",
      edgeEnableParallelLabel: "Edge: internal parallelism",
      edgeEnableParallelHint:
        "Enables parallel segment processing inside a chapter.",
      edgeEnableParallelOn: "Enabled",
      edgeEnableParallelOff: "Disabled",
      edgeAutoTuneLabel: "Edge: auto-tune",
      edgeAutoTuneHint:
        "Adapts chunk/segment settings to network and performance.",
      edgeAutoTuneOn: "Enabled",
      edgeAutoTuneOff: "Disabled",
      edgeStableModeLabel: "Edge: stable mode",
      edgeStableModeHint:
        "Forces lower parallelism and longer timeouts to reduce failures on long chapters.",
      edgeStableModeOn: "Stable",
      edgeStableModeOff: "Normal",
      engineChainFallbackLabel: "Engine chain fallback (legacy)",
      engineChainFallbackHint:
        "By default we stay on Edge; isolated failures use per-chunk fallback. Enable to restore the Edge → Piper cascade when Edge is rate-limited.",
      engineChainFallbackOn: "Cascade on",
      engineChainFallbackOff: "Edge only",
      piperMaxProcsLabel: "Piper: parallel processes",
      piperMaxProcsPlaceholder: "e.g., 3",
      piperMaxProcsHint: "Sets the max number of Piper processes.",
      audioLegend: "Audio output",
      bitrateLabel: "Bitrate (kbps)",
      bitratePlaceholder: "e.g., 8k",
      bitrateHint: "Lower values shrink files while keeping speech usable.",
      sampleRateLabel: "Sample rate (Hz)",
      sampleRatePlaceholder: "e.g., 16000",
      sampleRateHint: "16kHz is enough for voice; higher values increase size.",
      channelsLabel: "Channels",
      channelsHint: "Mono is recommended for audiobooks.",
      channelsMono: "Mono (1)",
      channelsStereo: "Stereo (2)",
      processingLegend: "Processing",
      verboseLabel: "Verbose logs",
      verboseDescription: "Show detailed engine output in the log panel.",
      verboseOn: "Enabled",
      verboseOff: "Reduced",
      clearCacheLabel: "Clear cache before converting",
      clearCacheDescription:
        "Removes cached text/audio for this book before starting.",
      clearCacheOn: "Clear",
      clearCacheOff: "Keep",
      forceReprocessLabel: "Force reprocess",
      forceReprocessDescription:
        "Ignores existing output and regenerates everything.",
      forceReprocessOn: "Force",
      forceReprocessOff: "Normal",
      filterChaptersLabel: "Filter short chapters",
      filterChaptersDescription:
        "Drops tiny sections when building the chapter list.",
      filterChaptersOn: "Filter",
      filterChaptersOff: "Keep",
      languageDetectionLegend: "Language detection",
      languageDetectionLabel: "Detect language in text",
      languageDetectionDescription:
        "Automatically tags passages in other languages.",
      languageDetectionOn: "Enabled",
      languageDetectionOff: "Disabled",
      prioritizePrimaryLanguageLabel: "Prioritize primary language",
      prioritizePrimaryLanguageDescription:
        "Keeps the book language when detection is ambiguous.",
      prioritizePrimaryLanguageOn: "Enabled",
      prioritizePrimaryLanguageOff: "Disabled",
      healthCheckLegend: "Auto healthcheck",
      healthCheckIntervalLabel: "Healthcheck interval (s)",
      healthCheckIntervalPlaceholder: "Auto (30)",
      healthCheckIntervalHint:
        "Checks slowdowns/resource use and adjusts parallelism.",
      healthCheckSlowEdgeCpsLabel: "Edge threshold (chars/s)",
      healthCheckSlowEdgeCpsPlaceholder: "Auto (EDGE_MIN)",
      healthCheckSlowEdgeCpsHint: "Below this, enable Edge safe mode.",
      healthCheckSlowCpsLabel: "Other engines threshold (chars/s)",
      healthCheckSlowCpsPlaceholder: "Auto (30)",
      healthCheckSlowCpsHint: "Below this, reduce parallelism for stability.",
      healthCheckHighCpuLabel: "High CPU (%)",
      healthCheckHighCpuPlaceholder: "Auto (85)",
      healthCheckHighCpuHint: "Above this, reduce parallelism.",
      healthCheckHighMemLabel: "High memory (%)",
      healthCheckHighMemPlaceholder: "Auto (85)",
      healthCheckHighMemHint: "Above this, reduce parallelism.",
      healthCheckOkCpuLabel: "CPU ok (%)",
      healthCheckOkCpuPlaceholder: "Auto (75)",
      healthCheckOkCpuHint: "Below this, can raise parallelism.",
      healthCheckOkMemLabel: "Memory ok (%)",
      healthCheckOkMemPlaceholder: "Auto (80)",
      healthCheckOkMemHint: "Below this, can raise parallelism.",
      healthCheckSlowStreakLabel: "Consecutive slow checks",
      healthCheckSlowStreakPlaceholder: "Auto (2)",
      healthCheckSlowStreakHint: "How many slow checks before adjusting.",
      sectionsLabel: "Extra sections (optional)",
      sectionsPlaceholder: "e.g., 2.1, 2.2, epilogue",
      sectionsHint: "Use alongside chapters to target subsections or titles.",
    },
    status: {
      phases: {
        idle: "Ready to start",
        submitting: "Uploading file…",
        polling: "Reading and converting…",
        success: "All done!",
        error: "Something went wrong",
        cancelling: "Cancelling…",
        cancelled: "Cancelled",
      },
      jobLabel: (jobId: string) => `Request ID: ${jobId}`,
      placeholder: "Upload a file to follow the step-by-step updates here.",
      errorPrefix: "Details: {message}",
      toggleShow: "Show terminal output",
      toggleHide: "Hide terminal output",
      etaLabel: "Estimated time",
      etaCalculating: "calculating…",
      etaSoon: "almost there",
      etaDone: "finished",
      cancelButton: "Stop conversion",
      cancelButtonPending: "Cancelling…",
      skipButton: "Skip to next",
      progressLabel: "Overall progress",
      summaryTitle: "Run summary",
      summaryLanguage: "Detected language",
      summaryChapters: "Total chapters",
      summaryCurrent: "Current chapter",
      summaryHint: "Realtime status",
      summaryProgress: "Progress",
      summaryParallel: "Parallel chapters",
      chapterProgressTitle: "Chapter progress",
      expandAllChapters: "Expand all",
      collapseAllChapters: "Collapse all",
      showAllText: "Show full text",
      hideAllText: "Hide text",
      scrollToTop: "Back to top",
      downloadFullText: "Download full text",
      searchPlaceholder: "Search in full text…",
      searchCount: (count: number) =>
        count === 1 ? "1 match" : `${count} matches`,
      searchPrev: "Previous",
      searchNext: "Next",
      readerTitle: "Synced reader",
      readerReadButton: "Read book",
      readerUnavailable:
        "Could not load the book text. Please try again in a moment.",
      readerStillExtracting:
        "Still extracting the book text… this can take a few seconds.",
      readerExtractionFailed:
        "Could not extract any chapter from this file. Please check that the EPUB/PDF is valid.",
      readerLoading: "Loading EPUB/PDF text…",
      readerEmpty: "Select a chapter to start reading.",
      readerOpen: "Open reader",
      readerClose: "Close reader",
      readerOpenPopup: "Open popup",
      readerExitPopup: "Exit popup",
      readerChaptersTitle: "Chapters",
      readerPageLabel: (current: number, total: number) =>
        `Page ${current} of ${total}`,
      readerPrevPage: "Previous page",
      readerNextPage: "Next page",
      readerFollowAudioLabel: "Follow audio",
      readerFollowAudioOn: "Following narration",
      readerFollowAudioOff: "Manual reading",
      readerThemeLabel: "Theme",
      readerThemePaper: "Paper",
      readerThemeMist: "Mist",
      readerThemeInk: "Ink",
      readerFontSizeLabel: "Font size",
      readerFontFamilyLabel: "Font",
      readerFontFamilySerif: "Serif",
      readerFontFamilySans: "Sans-serif",
      readerLineHeightLabel: "Line height",
      readerWidthLabel: "Column width",
      readerNowReading: "Now reading",
      readerWaitingSegment: "Waiting for next segment",
      readerPlaying: "Playing",
      readerPaused: "Paused",
      readerSegmentLabel: (index: number) => `Segment ${index}`,
      readerChapterCount: (count: number) =>
        count === 1 ? "chapter" : "chapters",
      readerAudioOnChapter: (index: number) => `Audio on ch. ${index}`,
      readerRetryLoad: "Retry loading",
      uiHealthTitle: "UI health",
      uiHealthSubtitle: (count: number) =>
        count === 1
          ? "1 recent issue detected"
          : `${count} recent issues detected`,
      uiHealthClear: "Clear notices",
      uiHealthDismiss: "Dismiss notice",
      chapterStatuses: {
        pending: "Queued",
        processing: "Converting",
        completed: "Done",
        skipped: "Skipped",
        failed: "Failed",
        cancelled: "Cancelled",
        retrying: "Retrying",
      },
      chapterCompletedIn: (value: string) => `Completed in ${value}`,
      chapterGoToCurrent: "Go to current",
      chapterGoToCurrentTitle: "Go to current chapter",
      chapterFullAudio: "Full chapter:",
      chapterSegmentsTitle: "Chapter segments",
      chapterSegmentCount: (count: number) =>
        count <= 0 ? "no segments yet" : `${count} segments`,
      chapterSegmentsNone: "No segments available",
      chapterSegmentsWaiting: "Waiting for segments...",
      chapterSegmentsLoading: "Loading segments...",
      chapterSegmentTitle: (index: number) => `Segment ${index}`,
      chapterSegmentShowText: "Show text",
      chapterSegmentHideText: "Hide text",
      chapterSegmentText: "Text",
      chapterSegmentsEmpty: "No segments available yet.",
      chapterAudioUnsupported: "Your browser does not support audio playback.",
      chapterEngineLabel: (engine: string) => `Engine: ${engine.toUpperCase()}`,
      bookFallbackTitle: "Uploaded book",
      bookFallbackAuthor: "Unknown author",
      uploadingFiles: "Uploading books…",
      errorCategoryHints: {
        rate_limit: "Rate limit reached. Please try again in a few minutes.",
        timeout: "Conversion took too long. Try a different engine.",
        network: "Network error. Check your connection and try again.",
        engine_unavailable: "No TTS engine available. Check the server logs.",
        audio_truncation:
          "Generated audio is shorter than expected. Try a shorter chapter.",
        incomplete_segments:
          "Incomplete audio segments. Edge-TTS may be overloaded.",
        invalid_audio: "Invalid audio file generated. Try a different engine.",
        cancelled: "Conversion cancelled by user.",
        file_not_found: "File not found. Please upload again.",
        auth: "Authentication error with the TTS service.",
      },
      ttsEngineLabel: "TTS Engine",
      speedLabel: "Speed",
      terminalLogLabel: "Terminal Log",
      coverPhaseSubmitting: "File uploaded",
      coverPhasePolling: "Reading and converting",
      coverPhaseSuccess: "Conversion completed",
      coverPhaseError: "Conversion interrupted",
      coverPhaseDefault: "Book selected",
      cachedJobsTitle: "Interrupted Conversions",
      cachedJobsClose: "Close notice",
      cachedJobsSingular:
        "We found 1 interrupted conversion. Do you want to resume it?",
      cachedJobsPlural: (count: number) =>
        `We found ${count} interrupted conversions. Do you want to resume one?`,
      cachedJobsResume: "Resume",
      cachedJobsRemove: (fileName: string) => `Remove ${fileName}`,
      cachedJobsJustNow: "just now",
      cachedJobsDaysAgo: (days: number) =>
        `${days} day${days > 1 ? "s" : ""} ago`,
      cachedJobsHoursAgo: (hours: number) =>
        `${hours} hour${hours > 1 ? "s" : ""} ago`,
      cachedJobsMinutesAgo: (minutes: number) =>
        `${minutes} minute${minutes > 1 ? "s" : ""} ago`,
    },
    downloads: {
      placeholder:
        "When the conversion finishes, the audio files will show up here to play or download.",
      noDownloadsAfterSuccess:
        "Conversion finished, but the files could not be loaded. Check recent conversions or start a new one.",
      resetWithDownloads: "Start another conversion",
      resetWithoutDownloads: "Clear form",
      audioNotSupported: "Your browser does not support audio playback.",
      downloadChapter: "⬇ Download MP3",
      downloadZip: "Download Complete Audiobook (ZIP)",
      downloadZipHint: (count: number) =>
        `Contains ${count} ${count === 1 ? "chapter" : "chapters"} in MP3`,
      orIndividual: "Or download/listen to individual chapters",
      downloadLog: "Download conversion.log",
      viewLog: "View conversion.log",
      hideLog: "Hide conversion.log",
      logLoading: "Loading conversion.log…",
      logError: (message: string) =>
        `Unable to load conversion.log (${message}).`,
      viewingJobTitle: (title: string) => `Listening to “${title}”`,
      viewingJobSubtitle:
        "These files came from a finished conversion. Jump back anytime to see the current downloads.",
      viewingJobBackToCurrent: "Back to current downloads",
      readyListTitle: "Books ready to download",
      readyListSubtitle:
        "Includes titles finished in this queue and earlier sessions.",
      readyListAction: "Open downloads",
      readyListDownloadAll: "Download all (ZIP)",
      readyListDownloadAllHint: "Opens each book ZIP in a new tab.",
      readyListItem: (count: number) =>
        count === 1 ? "1 chapter ready" : `${count} chapters ready`,
      readyListAriaLabel: "Available audiobooks",
      readyListTagCurrent: "Current session",
      readyListTagPast: "Past sessions",
      removeButton: "Remove",
      readyNotificationTitle: "Audiobook ready",
      readyNotificationBody: (title: string) => `“${title}” just finished.`,
      readyNotificationBodyFallback:
        "One of your books just finished converting.",
      shareTitle: "Share your audiobook",
      shareSubtitle: (book: string) =>
        `Send “${book}” to a friend or save the link for later listening.`,
      shareWhatsapp: "Share on WhatsApp",
      shareCopyLink: "Copy link",
      shareCopied: "Link copied!",
      shareCopyError: "Could not copy. Please copy manually.",
      shareNative: "Share…",
      shareNativeUnavailable:
        "Your browser could not open the share sheet. Use copy link instead.",
      shareUnavailable:
        "A link will appear here as soon as an output is available.",
      shareMessage: (book: string) =>
        `I just turned “${book}” into an audiobook with EPUB to MP3. Listen here:`,
      readyListCompletedAt: (value: string) => `Finished on ${value}`,
      readyListDuration: (value: string) => `Total time: ${value}`,
      durationHours: (value: number) => `${value}h`,
      durationMinutes: (value: number) => `${value}m`,
      durationSeconds: (value: number) => `${value}s`,
    },
    layout: {
      footer: "",
      closeNotification: "Close notification",
      updateAvailable: (version: string) => `Update v${version} available`,
      updateInstall: "Install & Restart",
      updateInstalling: "Installing...",
      updateDismiss: "Dismiss",
      updateInstallError: "Update installation failed. Please try again.",
      restartTitle: "Restart Python backend",
      restartDescription:
        "Interrupts all running conversions and clears the current queue.",
      restartButton: "Restart backend",
      restartProgress: "Restarting…",
      restartConfirm:
        "Restarting now will interrupt every running conversion and clear the queue. Continue?",
      restartConfirmYes: "Restart",
      restartConfirmNo: "Cancel",
      restartKeepCacheTitle: "Chapter cache",
      restartKeepCacheConfirm:
        "Do you want to keep the local cache (already-processed chapters)?",
      restartKeepCacheYes: "Keep",
      restartKeepCacheNo: "Don't keep",
      restartKeepFinishedTitle: "Finished files",
      restartKeepFinishedConfirm:
        "Do you want to keep finished conversions and their generated files?",
      restartKeepFinishedYes: "Keep",
      restartKeepFinishedNo: "Don't keep",
      restartNotifyTitle: "Restart requested",
      restartNotifyBody:
        "Backend restarting. Wait a few seconds and reload this page.",
      restartErrorBody:
        "Failed to restart automatically. Please restart the backend manually.",
      helpToggle: "Help & System",
      helpTitle: "Help and monitoring",
      helpClose: "Close panel",
      statsTitle: "System monitoring",
      statsLoading: "Collecting metrics…",
      statsUptime: "Uptime",
      statsCpu: "CPU",
      statsMemory: "Memory",
      statsQueue: "Queue",
      statsRunning: "Running",
      statsWorkers: "Workers",
      statsRecommendation: "Recommendation",
      statsGpu: "GPUs",
      statsError: "Could not load metrics. Ensure the backend is up to date.",
      statsOffline: "Backend unreachable. Please start the server.",
      statsLastUpdated: (value: string) => `Updated ${value}`,
      statsRetrying: (value: string) => `Retrying in ${value}`,
      statsTarget: "Target",
      statsGpuUsage: "Usage",
      statsGpuVram: "VRAM",
      statsGpuTemp: "Temp",
      tauriEngineWaiting: "Waiting for conversion engine to start…",
      tauriEngineErrorTitle: "Conversion engine error",
      tauriEngineRebuild: "Rebuild the sidecar:",
      telemetryTitle: "Telemetry",
      telemetryDescription:
        "TTS throughput per engine, based on recorded synthesis samples.",
      telemetryRefresh: "Refresh",
      telemetryRefreshing: "Refreshing…",
      telemetryErrorGeneric: "Failed to load telemetry.",
      telemetryEmptyState:
        "No telemetry samples yet — run a conversion to populate.",
      telemetryEngineHeader: "Engine",
      telemetrySamplesHeader: "Samples",
      telemetryAvgHeader: "Avg c/s",
      telemetryMinHeader: "Min c/s",
      telemetryMaxHeader: "Max c/s",
      telemetryRankedLabel: "Fastest → slowest",
      telemetryTimelineTitle: "Recent chapters",
      telemetryTimelineEmpty: "No recent samples.",
      telemetryTimelineLatest: "Latest first",
      telemetryTotalSamples: (count: number) => `${count} total samples`,
      telemetryUpdatedAt: (iso: string) =>
        `Updated ${new Date(iso).toLocaleTimeString()}`,
    },
    flow: {
      startUpload: "Sending file to the server…",
      startReuse: "Preparing conversion using the uploaded file…",
      jobCreated: (jobId: string) =>
        `Request ${jobId} received. Waiting for narration…`,
      resuming: "🔄 Resuming interrupted conversion…",
      loadingCache: "📦 Loading cached progress for this conversion...",
      completion: (count: number) =>
        `Finished conversion with ${count} audio file(s).`,
      failure: (message: string) => `Request failed: ${message}`,
      error: (message: string) => `Error: ${message}`,
      defaultFailure: "Conversion failed",
      defaultError: "Unexpected error",
      cancelRequested: "🛑 Cancel request received. Finishing current step…",
      cancelled: "Request cancelled by the user.",
      skipped: "Current book skipped, continuing with queue.",
      cancelFailed: (message: string) =>
        `Unable to cancel: ${message || "please try again"}`,
      skipConfirm:
        "Do you want to skip this book and continue with the next one in the queue?",
      backendOffline: "Conversion server unavailable",
      backendOfflineDetails:
        "Unable to reach the API. Start the backend (`python -m uvicorn python_app.server:app --reload --port 8000`) or use `python app.py` (port 7860) and set VITE_API_BASE accordingly.",
      backendConnecting: "Connecting to the conversion server…",
      backendOfflineBanner:
        "Python backend is offline. Start it locally on port 8000, or use `python app.py` on port 7860 and set VITE_API_BASE, then reload this page.",
      cachedRestoredSuccess:
        "Restored from local cache — downloads may be unavailable if the server was restarted.",
      cancelConfirm:
        "Cancelling now stops the current conversion and removes generated files. Continue?",
      batchPosition: (index: number, total: number) =>
        `📚 Book ${index}/${total}`,
      batchCancelled: (remaining: number) =>
        remaining === 1
          ? "Batch stopped. 1 book is still pending."
          : `Batch stopped. ${remaining} books are still pending.`,
      notificationErrorTitle: "Conversion failed",
      notificationErrorBody: "Check the log for more details.",
      notificationCancelTitle: "Conversion cancelled",
      notificationCancelBody:
        "Conversion cancelled and removed. You can start a new conversion whenever you want.",
    },
    queue: {
      title: "Queue more books",
      subtitle:
        "Files you add here reuse the Step 1 settings and run right after the current book.",
      inputLabel: "Select additional EPUB/PDF files",
      hint: "Keep watching the progress while the next books wait in the background.",
      addFolderButton: "Choose folder",
      success: (count: number) =>
        count === 1
          ? "1 book added to the queue."
          : `${count} books added to the queue.`,
      errorFallback: "Unable to add to the queue. Please try again.",
      phaseActive: "In progress",
      phaseSuccess: "Ready for next batch",
      displayCurrentLabel: "Converting now",
      displayQueueLabel: (count: number) =>
        `In queue: ${count} ${count === 1 ? "book" : "books"}`,
      displayMoreLabel: (count: number) => `+ ${count} more`,
      displayResumeButton: "▶ Resume queue",
      displayClearButton: "Clear queue",
      displayPausedBadge: "Paused",
      displayShowLess: "Show less",
      displayMoveUp: "Move up",
      displayMoveDown: "Move down",
    },
  },
};

export function resolveLocale(input?: string | null): Locale {
  if (!input) return "en";
  const normalised = input.toLowerCase();
  if (normalised.startsWith("pt")) return "pt";
  return "en";
}

export function getTranslations(locale: Locale): Translations {
  return translations[locale];
}
