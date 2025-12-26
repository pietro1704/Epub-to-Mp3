import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import ConversionForm from './components/ConversionForm';
import DownloadsPanel from './components/DownloadsPanel';
import Hero from './components/Hero';
import Layout from './components/Layout';
import Panel from './components/Panel';
import StatusPanel from './components/StatusPanel';
import RecentJobsPanel from './components/RecentJobsPanel';
import ResumableJobsPanel from './components/ResumableJobsPanel';
import QuickQueueAdder from './components/QuickQueueAdder';
import ActiveConversionBanner from './components/ActiveConversionBanner';
import ReadyDownloadsList, { ReadyDownloadJob } from './components/ReadyDownloadsList';
import { useConversionFlow } from './hooks/useConversionFlow';
import { useI18n, useTranslations } from './i18n/I18nProvider';
import type { ConversionClient } from './services/ConversionService';
import type { ConversionFormValues, ConversionState, RecentJobEntry, SubmitBatchOptions, ConversionTemplate } from './types/conversion';
import { formatEta } from './components/StatusPanel';

export interface AppProps {
  client?: ConversionClient;
}

export default function App(props?: AppProps): JSX.Element {
  const { client } = props ?? {};
  const { state, submit, enqueue, resume, reset, cancel, isBusy, cachedJobs, uploadFile, recentJobs, apiAvailable, healthStatus } = useConversionFlow(client);
  const [formVersion, setFormVersion] = useState(0);
  const [activeTab, setActiveTab] = useState<'setup' | 'progress' | 'downloads'>('setup');
  const [userSelectedTab, setUserSelectedTab] = useState(false);
  const [showRawLog, setShowRawLog] = useState(false);
  const [viewingRecentJob, setViewingRecentJob] = useState<RecentJobEntry | null>(null);
  const [repeatConfig, setRepeatConfig] = useState<ConversionTemplate | null>(null);
  const [batchHistory, setBatchHistory] = useState<RecentJobEntry[]>([]);
  const t = useTranslations();
  const { locale } = useI18n();
  const lastCompletedJobIdRef = useRef<string | null>(null);
  const manualDownloadOverrideRef = useRef(false);
  const lastPhaseRef = useRef<ConversionState['phase']>(state.phase);
  const notifiedBatchJobsRef = useRef<Set<string>>(new Set());

  const hasDownloads = Array.isArray(state.downloads) && state.downloads.length > 0;
  const canViewProgress = state.phase !== 'idle' || state.log.length > 0 || Boolean(state.summary) || Boolean(state.error) || Boolean(state.jobId);
  const canViewDownloads = hasDownloads || state.phase === 'success';

  const clearRecentJobView = useCallback(() => {
    manualDownloadOverrideRef.current = true;
    setViewingRecentJob(null);
  }, []);

  const handleReset = useCallback(() => {
    reset();
    setFormVersion((value) => value + 1);
    setActiveTab('setup');
    setUserSelectedTab(false);
    setShowRawLog(false);
    clearRecentJobView();
    setBatchHistory([]);
    lastCompletedJobIdRef.current = null;
  }, [clearRecentJobView, reset]);

  const handleTabChange = useCallback((tabId: 'setup' | 'progress' | 'downloads') => {
    const allowed = tabId === 'setup'
      ? true
      : tabId === 'progress'
        ? canViewProgress
        : canViewDownloads;
    if (!allowed) {
      return;
    }
    setActiveTab(tabId);
    setUserSelectedTab(true);
  }, [canViewDownloads, canViewProgress]);

  const handleSelectReadyDownload = useCallback((job: ReadyDownloadJob) => {
    manualDownloadOverrideRef.current = true;
    setViewingRecentJob(job);
    setActiveTab('downloads');
    setUserSelectedTab(true);
  }, []);

  const handleFormSubmit = useCallback(async (values: ConversionFormValues, options?: SubmitBatchOptions) => {
    setActiveTab('progress');
    setUserSelectedTab(false);
    clearRecentJobView();
    setRepeatConfig({
      engine: values.engine,
      voice: values.voice,
      chapters: values.chapters,
      priority: values.priority,
      footnoteMode: values.footnoteMode,
      language: values.language,
      formattingCues: values.formattingCues ?? true,
      uiLanguage: locale,
    });

    const queue = [values, ...(options?.batchQueue ?? [])].filter(Boolean);
    if (queue.length === 0) {
      return;
    }
    if (state.phase === 'idle') {
      const [first, ...rest] = queue;
      await submit(first, { batchQueue: rest });
      return;
    }
    await enqueue(queue);
  }, [clearRecentJobView, enqueue, state.phase, submit]);

  const handleCancelClick = useCallback(() => {
    if (!state.jobId) return;
    const message = t.flow.cancelConfirm;
    if (typeof window !== 'undefined' && typeof window.confirm === 'function') {
      if (!window.confirm(message)) {
        return;
      }
    }
    void (async () => {
      const cancelled = await cancel();
      if (cancelled) {
        handleReset();
      }
    })();
  }, [cancel, handleReset, state.jobId, t.flow.cancelConfirm]);

  const displayedDownloads = useMemo(() => {
    if (viewingRecentJob) {
      if (Array.isArray(viewingRecentJob.outputs) && viewingRecentJob.outputs.length > 0) {
        return viewingRecentJob.outputs;
      }
      if (viewingRecentJob.downloadUrl) {
        const fallbackName = viewingRecentJob.fileName || `${viewingRecentJob.bookTitle || 'book'}.zip`;
        return [
          {
            name: fallbackName,
            url: viewingRecentJob.downloadUrl,
          },
        ];
      }
    }
    return state.downloads;
  }, [state.downloads, viewingRecentJob]);

  const formatLanguageLabel = useCallback((code?: string | null) => {
    if (!code) return '';
    const options = t.form.languageOptions ?? {};
    if (options[code as keyof typeof options]) {
      return options[code as keyof typeof options];
    }
    const normalized = code.toLowerCase();
    if (options[normalized as keyof typeof options]) {
      return options[normalized as keyof typeof options];
    }
    const [base] = normalized.split(/[-_]/);
    if (base && options[base as keyof typeof options]) {
      return options[base as keyof typeof options];
    }
    return code.toUpperCase();
  }, [t.form.languageOptions]);

  const downloadsContext = useMemo(() => {
    if (!viewingRecentJob || !viewingRecentJob.outputs || viewingRecentJob.outputs.length === 0) {
      return undefined;
    }
    return {
      title: t.downloads.viewingJobTitle(viewingRecentJob.bookTitle),
      subtitle: t.downloads.viewingJobSubtitle,
      actionLabel: t.downloads.viewingJobBackToCurrent,
      onAction: clearRecentJobView,
    };
  }, [clearRecentJobView, t.downloads, viewingRecentJob]);

  const readyDownloadJobs = useMemo<ReadyDownloadJob[]>(() => {
    const dedup = new Map<string, ReadyDownloadJob>();
    const register = (job: RecentJobEntry | null | undefined, source: 'current' | 'recent') => {
      if (!job) return;
      const hasOutputs = Array.isArray(job.outputs) && job.outputs.length > 0;
      const hasDownload = hasOutputs || Boolean(job.downloadUrl) || Boolean(job.hasOutputs);
      if (!hasDownload) {
        return;
      }
      const savedAtMs = job.savedAt ? Date.parse(job.savedAt) : Date.now();
      const entry: ReadyDownloadJob = {
        ...job,
        source,
        savedAtMs: Number.isNaN(savedAtMs) ? Date.now() : savedAtMs,
      };
      if (!dedup.has(entry.jobId)) {
        dedup.set(entry.jobId, entry);
      }
    };

    batchHistory.forEach((job) => register(job, 'current'));
    recentJobs.forEach((job) => register(job, 'recent'));

    return Array.from(dedup.values()).sort((a, b) => (b.savedAtMs ?? 0) - (a.savedAtMs ?? 0));
  }, [batchHistory, recentJobs]);

  const currentEngine = state.engine ?? repeatConfig?.engine;
  const currentVoice = state.voice ?? repeatConfig?.voice;
  const currentLanguageLabel = formatLanguageLabel(state.summary?.detectedLanguage ?? state.language ?? repeatConfig?.language);

  const canCancelJob = Boolean(state.jobId && (state.phase === 'polling' || state.phase === 'cancelling'));
  const cancelDisabled = state.phase === 'cancelling';
  const activeEtaDisplay = formatEta(state.phase, state.etaSeconds, locale, t);
  const showActiveConversion = activeTab === 'setup' && state.phase !== 'idle';
  const canShowQueueAdder = Boolean(repeatConfig && state.phase !== 'idle');

  const formLocked = state.phase === 'submitting' || state.phase === 'cancelling';

  useEffect(() => {
    if (userSelectedTab) {
      return;
    }
    if (state.phase === 'success' || (hasDownloads && state.phase !== 'error' && state.phase !== 'cancelled')) {
      if (activeTab !== 'downloads') {
        setActiveTab('downloads');
      }
      return;
    }
    if (state.phase === 'error' || state.phase === 'cancelled') {
      if (activeTab !== 'progress') {
        setActiveTab('progress');
      }
      return;
    }
    if (state.phase === 'submitting' && activeTab !== 'progress') {
      setActiveTab('progress');
      return;
    }
    if (state.phase === 'polling' && activeTab !== 'progress') {
      setActiveTab('progress');
    }
  }, [state.phase, hasDownloads, activeTab, userSelectedTab]);

  useEffect(() => {
    if (typeof window === 'undefined' || !('Notification' in window)) {
      return;
    }
    if (Notification.permission === 'default') {
      Notification.requestPermission().catch(() => {});
    }
  }, []);

  useEffect(() => {
    if (state.phase !== 'success') {
      return;
    }
    if (!state.jobId || !Array.isArray(state.downloads) || state.downloads.length === 0) {
      return;
    }
    if (lastCompletedJobIdRef.current === state.jobId) {
      return;
    }
    const resolvedTitle = state.bookTitle?.trim() || t.status.bookFallbackTitle;
    const mp3Count = state.downloads.filter((asset) => asset.name.toLowerCase().endsWith('.mp3')).length;
    const chapterCount = mp3Count || state.summary?.chaptersCompleted || 0;
    const downloadUrl = state.downloads.find((asset) => asset.name.toLowerCase().endsWith('.zip'))?.url
      ?? state.downloads[0]?.url;
    const entry: RecentJobEntry = {
      jobId: state.jobId,
      state: 'finished',
      bookTitle: resolvedTitle,
      fileName: resolvedTitle,
      savedAt: new Date().toISOString(),
      outputs: state.downloads,
      downloadUrl,
      chaptersCompleted: state.summary?.chaptersCompleted ?? chapterCount,
      chaptersTotal: state.summary?.chaptersTotal ?? (chapterCount || undefined),
      progressPercent: 100,
      engine: state.engine,
      voice: state.voice,
      language: state.language ?? state.summary?.detectedLanguage,
      formattingCues: state.speakFormattingCues,
      uiLanguage: state.uiLanguage,
      hasOutputs: true,
      canResume: false,
    };
    setBatchHistory((prev) => {
      const next = [entry, ...prev.filter((job) => job.jobId !== entry.jobId)];
      return next.slice(0, 5);
    });
    manualDownloadOverrideRef.current = false;
    lastCompletedJobIdRef.current = state.jobId;
  }, [state.bookTitle, state.downloads, state.engine, state.language, state.phase, state.summary, state.jobId, state.speakFormattingCues, state.uiLanguage, state.voice, t.status.bookFallbackTitle]);

  useEffect(() => {
    if (!readyDownloadJobs.length) {
      return;
    }
    const currentJob = state.jobId ? readyDownloadJobs.find((job) => job.jobId === state.jobId) : undefined;
    if (state.phase === 'success' && currentJob) {
      if (!viewingRecentJob || viewingRecentJob.jobId !== currentJob.jobId || manualDownloadOverrideRef.current) {
        manualDownloadOverrideRef.current = false;
        setViewingRecentJob(currentJob);
      }
      return;
    }
    if (manualDownloadOverrideRef.current) {
      return;
    }
    const latest = readyDownloadJobs[0];
    if (!viewingRecentJob || viewingRecentJob.jobId !== latest.jobId) {
      setViewingRecentJob(latest);
    }
  }, [readyDownloadJobs, state.jobId, state.phase, viewingRecentJob]);

  useEffect(() => {
    if (typeof window === 'undefined' || !('Notification' in window)) {
      lastPhaseRef.current = state.phase;
      return;
    }
    if (Notification.permission !== 'granted') {
      lastPhaseRef.current = state.phase;
      return;
    }
    if (state.phase === lastPhaseRef.current) {
      return;
    }
    if (state.phase === 'success') {
      lastPhaseRef.current = state.phase;
      return;
    }
    if (state.phase === 'error') {
      new Notification(t.flow.notificationErrorTitle, {
        body: state.error || t.flow.notificationErrorBody,
      });
    }
    if (state.phase === 'cancelled') {
      new Notification(t.flow.notificationCancelTitle, {
        body: t.flow.notificationCancelBody,
      });
    }
    lastPhaseRef.current = state.phase;
  }, [state.phase, state.error, t.flow]);

  useEffect(() => {
    if (typeof window === 'undefined' || !('Notification' in window)) {
      return;
    }
    if (Notification.permission !== 'granted') {
      return;
    }
    batchHistory.forEach((job) => {
      if (!job.jobId || notifiedBatchJobsRef.current.has(job.jobId)) {
        return;
      }
      notifiedBatchJobsRef.current.add(job.jobId);
      const body = job.bookTitle
        ? t.downloads.readyNotificationBody(job.bookTitle)
        : t.downloads.readyNotificationBodyFallback;
      new Notification(t.downloads.readyNotificationTitle, {
        body,
      });
    });
  }, [batchHistory, t.downloads]);

  const tabs = useMemo(
    () => [
      {
        id: 'setup' as const,
        label: t.tabs.setup.label,
        description: t.tabs.setup.description,
        content: (
          <Panel
            title={t.tabs.setup.panelTitle}
            description={t.tabs.setup.panelDescription}
            footer={
              activeTab === 'setup' && state.phase !== 'idle' && (
                <div style={{ display: 'flex', justifyContent: 'flex-end', gap: '0.5rem' }}>
                  <button
                    type="button"
                    className="button-secondary"
                    onClick={() => handleTabChange('progress')}
                  >
                    Ver Progresso →
                  </button>
                </div>
              )
            }
          >
            {showActiveConversion && (
              <>
                <ActiveConversionBanner
                  phase={state.phase}
                  statusLabel={t.status.phases[state.phase]}
                  jobLabel={state.jobId ? t.status.jobLabel(state.jobId) : undefined}
                  bookTitle={state.bookTitle?.trim() || t.status.bookFallbackTitle}
                  bookAuthor={state.bookAuthor?.trim()}
                  etaLabel={t.activeConversion.etaLabel}
                  etaValue={activeEtaDisplay}
                  currentLabel={t.activeConversion.currentLabel}
                  engineLabel={t.activeConversion.engineLabel}
                  voiceLabel={t.activeConversion.voiceLabel}
                  languageLabel={t.activeConversion.languageLabel}
                  engineValue={currentEngine}
                  voiceValue={currentVoice}
                  languageValue={currentLanguageLabel}
                  description={t.activeConversion.description}
                  queueHint={t.activeConversion.queueHint}
                  viewLabel={t.activeConversion.viewProgress}
                  cancelLabel={t.activeConversion.cancel}
                  onViewProgress={() => handleTabChange('progress')}
                  onCancel={handleCancelClick}
                  canCancel={canCancelJob}
                  cancelDisabled={cancelDisabled}
                  summary={state.summary}
                />
                {canShowQueueAdder && repeatConfig && (
                  <QuickQueueAdder template={repeatConfig} enqueue={enqueue} phase={state.phase} />
                )}
              </>
            )}
            <ConversionForm
              key={formVersion}
              isSubmitting={formLocked}
              onSubmit={handleFormSubmit}
              onUploadFile={uploadFile}
              currentJob={{
                jobId: state.jobId,
                phase: state.phase,
                bookTitle: state.bookTitle,
                engine: currentEngine || undefined,
                voice: currentVoice || undefined,
                language: currentLanguageLabel || undefined,
                formattingCues: typeof state.speakFormattingCues === 'boolean'
                  ? state.speakFormattingCues
                  : repeatConfig?.formattingCues,
              }}
            />
          </Panel>
        ),
      },
      {
        id: 'progress' as const,
        label: t.tabs.progress.label,
        description: t.tabs.progress.description,
        content: (
          <Panel
            title={t.tabs.progress.panelTitle}
            description={t.tabs.progress.panelDescription}
            footer={
              activeTab === 'progress' && (
                <div style={{ display: 'flex', justifyContent: 'space-between', gap: '0.5rem' }}>
                  <button
                    type="button"
                    className="button-secondary"
                    onClick={() => handleTabChange('setup')}
                  >
                    ← Voltar
                  </button>
                  {state.phase === 'success' && (
                    <button
                      type="button"
                      className="button-secondary"
                      onClick={() => handleTabChange('downloads')}
                    >
                      Ver Downloads →
                    </button>
                  )}
                </div>
              )
            }
          >
            <StatusPanel
              entries={state.log}
              rawLog={state.rawLog}
              phase={state.phase}
              jobId={state.jobId}
              error={state.error}
              etaSeconds={state.etaSeconds}
              showRawLog={showRawLog}
              onToggleRawLog={() => setShowRawLog((value) => !value)}
              summary={state.summary}
              cliCommand={state.cliCommand}
              onCancel={state.jobId ? handleCancelClick : undefined}
              canCancel={canCancelJob}
              cancelDisabled={cancelDisabled}
              bookTitle={state.bookTitle}
              bookAuthor={state.bookAuthor}
              coverUrl={state.coverUrl}
            />
            {canShowQueueAdder && repeatConfig && (
              <QuickQueueAdder
                template={repeatConfig}
                enqueue={enqueue}
                phase={state.phase}
              />
            )}
            {readyDownloadJobs.length > 0 && (
              <div style={{ marginTop: '1.5rem' }}>
                <ReadyDownloadsList
                  jobs={readyDownloadJobs}
                  activeJobId={viewingRecentJob?.jobId}
                  onSelect={handleSelectReadyDownload}
                />
              </div>
            )}
          </Panel>
        ),
      },
      {
        id: 'downloads' as const,
        label: t.tabs.downloads.label,
        description: t.tabs.downloads.description,
        content: (
          <Panel
            title={t.tabs.downloads.panelTitle}
            description={t.tabs.downloads.panelDescription}
            footer={activeTab === 'downloads' && (
              <div style={{ display: 'flex', justifyContent: 'flex-start' }}>
                <button
                  type="button"
                  className="button-secondary"
                  onClick={() => handleTabChange('progress')}
                >
                  ← Voltar
                </button>
              </div>
            )}
          >
            {readyDownloadJobs.length > 0 && (
              <ReadyDownloadsList
                jobs={readyDownloadJobs}
                activeJobId={viewingRecentJob?.jobId}
                onSelect={handleSelectReadyDownload}
              />
            )}
            <DownloadsPanel
              downloads={displayedDownloads}
              phase={state.phase}
              onReset={handleReset}
              isBusy={isBusy}
              cliCommand={state.cliCommand}
              log={state.log}
              showRawLog={showRawLog}
              context={downloadsContext}
            />
          </Panel>
        ),
      },
    ],
    [activeTab, displayedDownloads, downloadsContext, enqueue, formVersion, handleFormSubmit, handleReset, handleSelectReadyDownload, handleTabChange, isBusy, readyDownloadJobs, repeatConfig, showRawLog, state.cliCommand, state.error, state.etaSeconds, state.jobId, state.log, state.phase, state.summary, t, viewingRecentJob],
  );

  const handleResumeJob = useCallback((jobId: string) => {
    setActiveTab('progress');
    clearRecentJobView();
    resume(jobId);
  }, [clearRecentJobView, resume]);

  const handleViewRecentJobOutputs = useCallback((job: RecentJobEntry) => {
    manualDownloadOverrideRef.current = true;
    if (job.outputs && job.outputs.length > 0) {
      setViewingRecentJob(job);
    } else {
      clearRecentJobView();
    }
    setActiveTab('downloads');
    setUserSelectedTab(true);
  }, [clearRecentJobView, setActiveTab, setUserSelectedTab, setViewingRecentJob]);


  const showSetupPanels = activeTab === 'setup' && state.phase === 'idle';
  const showOfflineBanner = showSetupPanels && healthStatus === 'fail';

  return (
    <Layout>
      <Hero
        title={state.bookTitle}
        author={state.bookAuthor}
        coverUrl={state.coverUrl}
        summary={state.summary}
        etaSeconds={state.etaSeconds}
        phase={state.phase}
        engineLabel={currentEngine}
        voiceLabel={currentVoice}
        languageLabel={currentLanguageLabel}
      />
      {showOfflineBanner && (
        <div className="api-offline-banner" role="alert">
          <strong>{t.flow.backendOffline}</strong>
          <span>{t.flow.backendOfflineBanner}</span>
        </div>
      )}
      {showSetupPanels && cachedJobs.length > 0 && (
        <ResumableJobsPanel jobs={cachedJobs} onResume={handleResumeJob} />
      )}
      {showSetupPanels && (
        <RecentJobsPanel
          jobs={recentJobs}
          onResume={handleResumeJob}
          onViewOutputs={handleViewRecentJobOutputs}
        />
      )}
      <section className="tabs">
        <div className="tabs__list" role="tablist" aria-label="Fluxo de conversão">
          {tabs.map((tab) => {
            const buttonId = `tab-${tab.id}`;
            const panelId = `panel-${tab.id}`;
            const isActive = activeTab === tab.id;
            const isDisabled = tab.id === 'setup'
              ? false
              : tab.id === 'progress'
                ? !canViewProgress
                : !canViewDownloads;
            return (
              <button
                key={tab.id}
                id={buttonId}
                type="button"
                role="tab"
                className={`tabs__trigger${isActive ? ' tabs__trigger--active' : ''}${isDisabled ? ' tabs__trigger--disabled' : ''}`}
                aria-selected={isActive}
                aria-controls={panelId}
                onClick={() => handleTabChange(tab.id)}
                disabled={isDisabled}
                aria-disabled={isDisabled}
              >
                <div className="tabs__header">
                  <span className="tabs__label">{tab.label}</span>
                  {tab.id === 'progress' && state.phase !== 'idle' && t.tabs.progress.activeBadge && (
                    <span className="tabs__badge">{t.tabs.progress.activeBadge}</span>
                  )}
                </div>
                <span className="tabs__description">{tab.description}</span>
              </button>
            );
          })}
        </div>
        <div className="tabs__panels">
          {tabs.map((tab) => {
            const panelId = `panel-${tab.id}`;
            const buttonId = `tab-${tab.id}`;
            const isHidden = activeTab !== tab.id;
            return (
              <div
                key={tab.id}
                role="tabpanel"
                id={panelId}
                aria-labelledby={buttonId}
                hidden={isHidden}
                className="tabs__panel"
              >
                {tab.content}
              </div>
            );
          })}
        </div>
      </section>
    </Layout>
  );
}
