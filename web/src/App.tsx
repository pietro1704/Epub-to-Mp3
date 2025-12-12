import { useCallback, useEffect, useMemo, useState } from 'react';
import CachedJobsAlert from './components/CachedJobsAlert';
import ConversionForm from './components/ConversionForm';
import DownloadsPanel from './components/DownloadsPanel';
import Hero from './components/Hero';
import Layout from './components/Layout';
import Panel from './components/Panel';
import StatusPanel from './components/StatusPanel';
import { useConversionFlow } from './hooks/useConversionFlow';
import { useTranslations } from './i18n/I18nProvider';
import type { ConversionClient } from './services/ConversionService';

export interface AppProps {
  client?: ConversionClient;
}

export default function App(props?: AppProps): JSX.Element {
  const { client } = props ?? {};
  const { state, submit, resume, reset, isBusy, cachedJobs } = useConversionFlow(client);
  const [formVersion, setFormVersion] = useState(0);
  const [activeTab, setActiveTab] = useState<'setup' | 'progress' | 'downloads'>('setup');
  const [showRawLog, setShowRawLog] = useState(false);
  const [showCachedAlert, setShowCachedAlert] = useState(true);
  const t = useTranslations();

  const handleReset = useCallback(() => {
    reset();
    setFormVersion((value) => value + 1);
    setActiveTab('setup');
    setShowRawLog(false);
  }, [reset]);

  useEffect(() => {
    if (state.phase === 'polling' && activeTab !== 'progress') {
      setActiveTab('progress');
    }
    if (state.phase === 'success' && activeTab !== 'downloads') {
      setActiveTab('downloads');
    }
    if (state.phase === 'error') {
      setActiveTab('progress');
    }
  }, [state.phase, activeTab]);

  const tabs = useMemo(
    () => [
      {
        id: 'setup' as const,
        label: t.tabs.setup.label,
        description: t.tabs.setup.description,
        content: (
          <Panel title={t.tabs.setup.panelTitle} description={t.tabs.setup.panelDescription}>
            <ConversionForm key={formVersion} isSubmitting={isBusy} onSubmit={submit} />
          </Panel>
        ),
      },
      {
        id: 'progress' as const,
        label: t.tabs.progress.label,
        description: t.tabs.progress.description,
        content: (
          <Panel title={t.tabs.progress.panelTitle} description={t.tabs.progress.panelDescription}>
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
            footer={<small>{t.tabs.downloads.footer}</small>}
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
    [formVersion, handleReset, isBusy, showRawLog, state.downloads, state.error, state.etaSeconds, state.jobId, state.log, state.phase, state.summary, submit, t],
  );

  const handleResumeJob = useCallback((jobId: string) => {
    setActiveTab('progress');
    setShowCachedAlert(false);
    resume(jobId);
  }, [resume]);

  return (
    <Layout>
      <Hero />
      {showCachedAlert && cachedJobs.length > 0 && (
        <CachedJobsAlert
          cachedJobs={cachedJobs}
          onResume={handleResumeJob}
          onDismiss={() => setShowCachedAlert(false)}
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
                onClick={() => setActiveTab(tab.id)}
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
