import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import CachedJobsAlert from './components/CachedJobsAlert';
import ConversionForm from './components/ConversionForm';
import DownloadsPanel from './components/DownloadsPanel';
import Hero from './components/Hero';
import Layout from './components/Layout';
import Panel from './components/Panel';
import StatusPanel from './components/StatusPanel';
import BookCoverCard from './components/BookCoverCard';
import { useConversionFlow } from './hooks/useConversionFlow';
import { useTranslations } from './i18n/I18nProvider';
import type { ConversionClient } from './services/ConversionService';
import type { ConversionFormValues, ConversionState } from './types/conversion';

export interface AppProps {
  client?: ConversionClient;
}

const CACHED_ALERT_DISMISSED_KEY = 'ebook-tts-cached-alert-dismissed';

export default function App(props?: AppProps): JSX.Element {
  const { client } = props ?? {};
  const { state, submit, resume, reset, cancel, cancelJobById, removeCachedJob, isBusy, cachedJobs, uploadFile } = useConversionFlow(client);
  const [formVersion, setFormVersion] = useState(0);
  const [activeTab, setActiveTab] = useState<'setup' | 'progress' | 'downloads'>('setup');
  const [userSelectedTab, setUserSelectedTab] = useState(false);
  const [showRawLog, setShowRawLog] = useState(false);
  const [showCachedAlert, setShowCachedAlert] = useState(() => {
    try {
      return localStorage.getItem(CACHED_ALERT_DISMISSED_KEY) !== 'true';
    } catch {
      return true;
    }
  });
  const t = useTranslations();

  // Re-show alert when new cached jobs appear
  useEffect(() => {
    if (cachedJobs.length > 0) {
      try {
        const isDismissed = localStorage.getItem(CACHED_ALERT_DISMISSED_KEY) === 'true';
        if (isDismissed) {
          // Check if we have a stored job count
          const storedCount = localStorage.getItem('ebook-tts-cached-count');
          const previousCount = storedCount ? parseInt(storedCount, 10) : 0;

          // If new jobs appeared, reset the dismissed state
          if (cachedJobs.length > previousCount) {
            localStorage.removeItem(CACHED_ALERT_DISMISSED_KEY);
            setShowCachedAlert(true);
          }
        }

        // Update stored count
        localStorage.setItem('ebook-tts-cached-count', cachedJobs.length.toString());
      } catch (error) {
        console.warn('[App] Failed to check cached jobs count:', error);
      }
    }
  }, [cachedJobs.length]);

  const handleReset = useCallback(() => {
    reset();
    setFormVersion((value) => value + 1);
    setActiveTab('setup');
    setUserSelectedTab(false);
    setShowRawLog(false);
  }, [reset]);

  const handleTabChange = useCallback((tabId: 'setup' | 'progress' | 'downloads') => {
    setActiveTab(tabId);
    setUserSelectedTab(true);
  }, []);

  const handleFormSubmit = useCallback(async (values: ConversionFormValues) => {
    setActiveTab('progress');
    setUserSelectedTab(false);
    await submit(values);
  }, [submit]);

  useEffect(() => {
    const hasDownloads = Array.isArray(state.downloads) && state.downloads.length > 0;
    if (state.phase === 'success' || (hasDownloads && state.phase !== 'error' && state.phase !== 'cancelled')) {
      if (activeTab !== 'downloads') {
        setActiveTab('downloads');
      }
      setUserSelectedTab(false);
      return;
    }
    if (state.phase === 'error' || state.phase === 'cancelled') {
      if (activeTab !== 'progress') {
        setActiveTab('progress');
      }
      setUserSelectedTab(false);
      return;
    }
    if (state.phase === 'submitting' && activeTab !== 'progress') {
      setActiveTab('progress');
      return;
    }
    if (!userSelectedTab && state.phase === 'polling' && activeTab !== 'progress') {
      setActiveTab('progress');
    }
  }, [state.phase, state.downloads, activeTab, userSelectedTab]);

  useEffect(() => {
    if (typeof window === 'undefined' || !('Notification' in window)) {
      return;
    }
    if (Notification.permission === 'default') {
      Notification.requestPermission().catch(() => {});
    }
  }, []);

  const lastPhaseRef = useRef<ConversionState['phase']>(state.phase);
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
      new Notification('Conversão concluída', {
        body: state.bookTitle ? `“${state.bookTitle}” está pronto para download.` : 'Seu audiobook está pronto.',
      });
    }
    if (state.phase === 'error') {
      new Notification('Conversão falhou', {
        body: state.error || 'Ocorreu um erro. Verifique o log.',
      });
    }
    if (state.phase === 'cancelled') {
      new Notification('Conversão cancelada', {
        body: 'Você pode retomar nas conversões interrompidas.',
      });
    }
    lastPhaseRef.current = state.phase;
  }, [state.phase, state.bookTitle, state.error]);

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
                    className="button button--secondary"
                    onClick={() => handleTabChange('progress')}
                  >
                    Ver Progresso →
                  </button>
                </div>
              )
            }
          >
            <ConversionForm
              key={formVersion}
              isSubmitting={isBusy}
              onSubmit={handleFormSubmit}
              onUploadFile={uploadFile}
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
                    className="button button--secondary"
                    onClick={() => handleTabChange('setup')}
                  >
                    ← Voltar
                  </button>
                  {state.phase === 'success' && (
                    <button
                      type="button"
                      className="button button--secondary"
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
              phase={state.phase}
              jobId={state.jobId}
              error={state.error}
              etaSeconds={state.etaSeconds}
              showRawLog={showRawLog}
              onToggleRawLog={() => setShowRawLog((value) => !value)}
              summary={state.summary}
              cliCommand={state.cliCommand}
              onCancel={state.jobId ? cancel : undefined}
              canCancel={Boolean(state.jobId && (state.phase === 'polling' || state.phase === 'cancelling'))}
              cancelDisabled={state.phase === 'cancelling'}
            />
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
                  className="button button--secondary"
                  onClick={() => handleTabChange('progress')}
                >
                  ← Voltar
                </button>
              </div>
            )}
          >
            <DownloadsPanel
              downloads={state.downloads}
              phase={state.phase}
              onReset={handleReset}
              isBusy={isBusy}
              cliCommand={state.cliCommand}
              log={state.log}
            />
          </Panel>
        ),
      },
    ],
    [activeTab, formVersion, handleFormSubmit, handleReset, handleTabChange, isBusy, showRawLog, state.cliCommand, state.downloads, state.error, state.etaSeconds, state.jobId, state.log, state.phase, state.summary, t],
  );

  const handleDismissAlert = useCallback(() => {
    setShowCachedAlert(false);
    try {
      localStorage.setItem(CACHED_ALERT_DISMISSED_KEY, 'true');
    } catch (error) {
      console.warn('[App] Failed to save alert dismissed state:', error);
    }
  }, []);

  const handleResumeJob = useCallback((jobId: string) => {
    setActiveTab('progress');
    handleDismissAlert();
    resume(jobId);
  }, [resume, handleDismissAlert]);

  const handleRemoveCachedJob = useCallback(async (jobId: string) => {
    handleDismissAlert();
    await cancelJobById(jobId);
    removeCachedJob(jobId);
    try {
      localStorage.setItem('ebook-tts-cached-count', Math.max(cachedJobs.length - 1, 0).toString());
    } catch (error) {
      console.warn('[App] Failed to update cached counter:', error);
    }
  }, [cancelJobById, removeCachedJob, handleDismissAlert, cachedJobs.length]);

  return (
    <Layout>
      <Hero />
      <BookCoverCard
        title={state.bookTitle}
        author={state.bookAuthor}
        coverUrl={state.coverUrl}
        phase={state.phase}
      />
      {showCachedAlert && cachedJobs.length > 0 && (
        <CachedJobsAlert
          cachedJobs={cachedJobs}
          onResume={handleResumeJob}
          onDismiss={handleDismissAlert}
          onRemove={handleRemoveCachedJob}
        />
      )}
      <section className="tabs">
        <div className="tabs__list" role="tablist" aria-label="Fluxo de conversão">
          {tabs.map((tab) => {
            const buttonId = `tab-${tab.id}`;
            const panelId = `panel-${tab.id}`;
            const isActive = activeTab === tab.id;
            return (
              <button
                key={tab.id}
                id={buttonId}
                type="button"
                role="tab"
                className={`tabs__trigger${isActive ? ' tabs__trigger--active' : ''}`}
                aria-selected={isActive}
                aria-controls={panelId}
                onClick={() => handleTabChange(tab.id)}
              >
                <span className="tabs__label">{tab.label}</span>
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
