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
  localRuntime: string;
  localInstallHelp: string;
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
