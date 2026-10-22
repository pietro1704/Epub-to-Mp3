import { Suspense } from 'react';
import Hero from './components/Hero';
import Layout from './components/Layout';
import { isTauri } from './lib/tauri';
import type { ConversionFormValues } from './types/conversion';
import {
  RecentJobsPanel,
  ResumableJobsPanel,
  SystemStatsPanel,
  TelemetryPanel,
  ConversionHistoryPanel,
  ConfirmDialog,
  ComponentFallback,
  StartupLogView,
} from './ApplicationPresentation';
import type { AppScope } from './useApplicationWorkspaces';

export function AppView({
  activeTab,
  state,
  healthStatus,
  currentEngine,
  currentVoice,
  currentLanguageLabel,
  queuePosition,
  queueTotal,
  setIsHelpOpen,
  isHelpOpen,
  t,
  apiHealthLabel,
  tauriStarting,
  tauriStartupLog,
  setStartupLogsExpanded,
  startupLogsExpanded,
  tauriEngineError,
  savedBatch,
  resumeBatch,
  dismissSavedBatch,
  cachedJobsLoading,
  visibleCachedJobs,
  handleResumeJob,
  handleRemoveResumableJob,
  renderQueueDisplay,
  completedRecentJobs,
  handleViewRecentJobOutputs,
  handleRemoveRecentJob,
  hasBackendDiagnostics,
  tabs,
  canViewProgress,
  canViewDownloads,
  handleTabChange,
  statusLabelOverride,
  systemStats,
  systemStatsLabels,
  systemStatsError,
  systemStatsLoading,
  systemStatsUpdatedAt,
  systemStatsNextRetry,
  telemetryLabels,
  handleRestartBackend,
  isRestartingBackend,
  isHfSpace,
  hfNotifications,
  dismissHfNotification,
  restartDialog,
  handleRestartDialogConfirm,
  handleRestartDialogCancel,
  handleRestartDialogClose,
}: AppScope): JSX.Element {
  const showSetupPanels = activeTab === 'setup' && state.phase === 'idle';

  // In Tauri mode the banner is replaced by a more specific engine error message.
  const showOfflineBanner = showSetupPanels && healthStatus === 'fail' && !isTauri();

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
        queuePosition={queuePosition}
        queueTotal={queueTotal}
      />
      <div className="help-toggle">
        <button
          type="button"
          onClick={() => setIsHelpOpen(true)}
          aria-expanded={isHelpOpen}
          aria-controls="help-drawer"
        >
          {t.layout.helpToggle}
        </button>
      </div>
      {showOfflineBanner && (
        <div className="api-offline-banner" role="alert">
          <strong>{t.flow.backendOffline}</strong>
          <span>{t.flow.backendOfflineBanner}</span>
          <span>API: {apiHealthLabel}</span>
        </div>
      )}
      {isTauri() && tauriStarting && showSetupPanels && (
        <div className="startup-log-panel" role="status">
          <div className="startup-log-panel__header">
            <span className="startup-log-panel__spinner" aria-hidden="true" />
            <strong>Starting conversion engine…</strong>
            <span className="startup-log-panel__hint">
              {tauriStartupLog.length === 0
                ? 'First launch may download ffmpeg (~60 MB)'
                : tauriStartupLog[tauriStartupLog.length - 1]}
            </span>
            <button
              type="button"
              className="startup-log-panel__toggle"
              onClick={() => setStartupLogsExpanded((v) => !v)}
              aria-expanded={startupLogsExpanded}
            >
              {startupLogsExpanded ? 'Hide logs ▲' : 'Show logs ▼'}
            </button>
          </div>
          {startupLogsExpanded && (
            <StartupLogView
              lines={tauriStartupLog.length > 0 ? tauriStartupLog : [t.layout.tauriEngineWaiting]}
            />
          )}
        </div>
      )}
      {isTauri() && !tauriStarting && tauriEngineError && showSetupPanels && (
        <div className="api-offline-banner" role="alert">
          <strong>{t.layout.tauriEngineErrorTitle}</strong>
          <span>{tauriEngineError}</span>
          <span>
            {t.layout.tauriEngineRebuild}{' '}
            <code>mise run desktop:sidecar &amp;&amp; mise run desktop:build</code>
          </span>
        </div>
      )}
      {showSetupPanels &&
        savedBatch &&
        savedBatch.length > 0 &&
        (() => {
          const resumableCount = savedBatch.filter(
            (item: ConversionFormValues) => item.file instanceof File || Boolean(item.uploadId),
          ).length;
          const needsReuploadCount = savedBatch.length - resumableCount;
          return (
            <div
              style={{
                display: 'flex',
                flexDirection: 'column',
                gap: '0.4rem',
                padding: '0.75rem 1rem',
                marginBottom: '1rem',
                background: 'var(--color-surface-raised, #f0f4ff)',
                border: '1px solid var(--color-border, #c8d4f0)',
                borderRadius: '8px',
              }}
            >
              <div
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'space-between',
                  gap: '0.75rem',
                }}
              >
                <span style={{ fontSize: '0.9rem' }}>
                  {t.tabs.setup.savedBatchTitle(savedBatch.length)}
                </span>
                <div style={{ display: 'flex', gap: '0.5rem' }}>
                  {resumableCount > 0 && (
                    <button
                      type="button"
                      className="button-primary"
                      onClick={() => resumeBatch(savedBatch)}
                    >
                      {t.tabs.setup.savedBatchResume}
                    </button>
                  )}
                  <button type="button" className="button-secondary" onClick={dismissSavedBatch}>
                    {t.tabs.setup.savedBatchDismiss}
                  </button>
                </div>
              </div>
              {needsReuploadCount > 0 && (
                <span
                  style={{
                    fontSize: '0.8rem',
                    color: 'var(--color-warning, #b45309)',
                  }}
                >
                  {t.tabs.setup.savedBatchNeedsReupload(needsReuploadCount)}
                </span>
              )}
            </div>
          );
        })()}
      {showSetupPanels && (cachedJobsLoading || visibleCachedJobs.length > 0) && (
        <Suspense fallback={<ComponentFallback />}>
          <ResumableJobsPanel
            jobs={visibleCachedJobs}
            onResume={handleResumeJob}
            onRemove={handleRemoveResumableJob}
            queueDisplay={renderQueueDisplay({ margin: '0.75rem 0 0' })}
            loading={cachedJobsLoading}
          />
        </Suspense>
      )}
      {showSetupPanels && completedRecentJobs.length > 0 && (
        <>
          <Suspense fallback={<ComponentFallback />}>
            <RecentJobsPanel
              jobs={completedRecentJobs}
              onViewOutputs={handleViewRecentJobOutputs}
              onRemoveJob={handleRemoveRecentJob}
            />
          </Suspense>
          {renderQueueDisplay({ marginTop: '1rem' })}
        </>
      )}
      {showSetupPanels && hasBackendDiagnostics && (
        <Suspense fallback={null}>
          <ConversionHistoryPanel />
        </Suspense>
      )}
      <section className="tabs">
        <div className="tabs__list" role="tablist" aria-label="Conversion flow">
          {tabs.map((tab) => {
            const buttonId = `tab-${tab.id}`;
            const panelId = `panel-${tab.id}`;
            const isActive = activeTab === tab.id;
            const isDisabled =
              tab.id === 'setup'
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
                  {tab.id === 'progress' &&
                    (state.phase === 'polling' || state.phase === 'submitting') &&
                    t.tabs.progress.activeBadge && (
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
      {isHelpOpen && (
        <div
          className="help-drawer__overlay"
          role="button"
          tabIndex={0}
          aria-label={t.layout.helpClose}
          onClick={() => setIsHelpOpen(false)}
          onKeyDown={(event) => {
            if (event.key === 'Enter' || event.key === ' ') {
              event.preventDefault();
              setIsHelpOpen(false);
            }
          }}
        />
      )}
      <aside
        id="help-drawer"
        className={`help-drawer${isHelpOpen ? ' help-drawer--open' : ''}`}
        aria-hidden={!isHelpOpen}
      >
        <div className="help-drawer__header">
          <strong>{t.layout.helpTitle}</strong>
          <button
            type="button"
            className="help-drawer__close"
            onClick={() => setIsHelpOpen(false)}
            aria-label={t.layout.helpClose}
          >
            ×
          </button>
        </div>
        {!hasBackendDiagnostics && isHelpOpen && (
          <section aria-label={t.layout.localRuntime}>
            <h2>{t.layout.localRuntime}</h2>
            <p>{t.form.ttsPreferences.capability}</p>
            <p>{t.layout.localInstallHelp}</p>
            <p>{statusLabelOverride}</p>
            {state.error && <p role="alert">{state.error}</p>}
            {state.jobId && <p>{t.status.jobLabel(state.jobId)}</p>}
            {typeof state.summary?.progressPercent === 'number' && (
              <p>
                {t.status.progressLabel}: {Math.round(state.summary.progressPercent)}%
              </p>
            )}
          </section>
        )}
        {hasBackendDiagnostics && isHelpOpen && (
          <>
            <Suspense fallback={<ComponentFallback />}>
              <SystemStatsPanel
                stats={systemStats}
                labels={systemStatsLabels}
                hasError={systemStatsError}
                isLoading={systemStatsLoading}
                updatedAt={systemStatsUpdatedAt}
                nextRetryMs={systemStatsNextRetry}
              />
            </Suspense>
            <Suspense fallback={<ComponentFallback />}>
              <TelemetryPanel labels={telemetryLabels} />
            </Suspense>
            <div className="system-control">
              <div className="system-control__text">
                <strong>{t.layout.restartTitle}</strong>
                <p>{t.layout.restartDescription}</p>
              </div>
              <button
                type="button"
                className="button-danger"
                onClick={handleRestartBackend}
                disabled={isRestartingBackend}
              >
                {isRestartingBackend ? t.layout.restartProgress : t.layout.restartButton}
              </button>
            </div>
          </>
        )}
      </aside>
      {isHfSpace && hfNotifications.length > 0 && (
        <div className="hf-notifications" role="region" aria-live="polite" aria-atomic="false">
          {hfNotifications.map((notification) => (
            <div
              key={notification.id}
              className={`hf-notification hf-notification--${notification.variant}`}
              role="status"
            >
              <button
                type="button"
                className="hf-notification__close"
                onClick={() => dismissHfNotification(notification.id)}
                aria-label={t.layout.closeNotification}
              >
                ×
              </button>
              <div className="hf-notification__title">{notification.title}</div>
              {notification.body && (
                <div className="hf-notification__body">{notification.body}</div>
              )}
            </div>
          ))}
        </div>
      )}

      {/* Restart backend dialogs */}
      <Suspense fallback={null}>
        <ConfirmDialog
          open={restartDialog === 'confirm'}
          title={t.layout.restartTitle}
          message={t.layout.restartConfirm}
          confirmLabel={t.layout.restartConfirmYes}
          cancelLabel={t.layout.restartConfirmNo}
          onConfirm={handleRestartDialogConfirm}
          onCancel={handleRestartDialogCancel}
          variant="danger"
        />
        <ConfirmDialog
          open={restartDialog === 'cache'}
          title={t.layout.restartKeepCacheTitle}
          message={t.layout.restartKeepCacheConfirm}
          confirmLabel={t.layout.restartKeepCacheYes}
          cancelLabel={t.layout.restartKeepCacheNo}
          onConfirm={handleRestartDialogConfirm}
          onCancel={handleRestartDialogCancel}
          onClose={handleRestartDialogClose}
          showCloseButton
        />
        <ConfirmDialog
          open={restartDialog === 'finished'}
          title={t.layout.restartKeepFinishedTitle}
          message={t.layout.restartKeepFinishedConfirm}
          confirmLabel={t.layout.restartKeepFinishedYes}
          cancelLabel={t.layout.restartKeepFinishedNo}
          onConfirm={handleRestartDialogConfirm}
          onCancel={handleRestartDialogCancel}
          onClose={handleRestartDialogClose}
          showCloseButton
        />
      </Suspense>
    </Layout>
  );
}
