import { Suspense, useMemo } from 'react';
import Panel from './components/Panel';
import {
  ConversionForm,
  DownloadsPanel,
  StatusPanel,
  QuickQueueAdder,
  ActiveConversionBanner,
  ReadyDownloadsList,
  ComponentFallback,
} from './ApplicationPresentation';
import type { ApplicationStateScope } from './useApplicationState';
import type { WorkspaceIntentsScope } from './useWorkspaceIntents';
import type { PlaybackWorkspaceScope } from './usePlaybackWorkspace';
import type { QueueDisplayScope } from './useQueueDisplay';

type WorkspaceTabsInput = Pick<
  ApplicationStateScope,
  | 't'
  | 'activeTab'
  | 'state'
  | 'repeatConfig'
  | 'enqueue'
  | 'uploadFile'
  | 'formVersion'
  | 'setPendingUploads'
  | 'showRawLog'
  | 'setShowRawLog'
  | 'setUserSelectedTab'
  | 'viewingRecentJob'
  | 'isBusy'
> &
  Pick<
    WorkspaceIntentsScope,
    | 'showUploadingStatus'
    | 'handleTabChange'
    | 'statusLabelOverride'
    | 'handleCancelClick'
    | 'handleSkipClick'
    | 'handleQueueJobsAdded'
    | 'formLocked'
    | 'handleFormSubmit'
    | 'handleSubmitIntent'
    | 'handleSelectReadyDownload'
    | 'handleRemoveRecentJob'
    | 'handleReset'
  > &
  Pick<
    PlaybackWorkspaceScope,
    | 'showActiveConversion'
    | 'activeEtaDisplay'
    | 'currentEngine'
    | 'currentVoice'
    | 'currentLanguageLabel'
    | 'canCancelJob'
    | 'canSkipJob'
    | 'cancelDisabled'
    | 'canShowQueueAdder'
    | 'readyDownloadJobs'
    | 'displayedDownloads'
    | 'downloadsContext'
    | 'shareDownloadTitle'
  > &
  Pick<QueueDisplayScope, 'renderQueueDisplay'>;

export function useWorkspaceTabs({
  t,
  activeTab,
  state,
  showUploadingStatus,
  handleTabChange,
  renderQueueDisplay,
  showActiveConversion,
  statusLabelOverride,
  activeEtaDisplay,
  currentEngine,
  currentVoice,
  currentLanguageLabel,
  handleCancelClick,
  handleSkipClick,
  canCancelJob,
  canSkipJob,
  cancelDisabled,
  canShowQueueAdder,
  repeatConfig,
  enqueue,
  uploadFile,
  handleQueueJobsAdded,
  formVersion,
  formLocked,
  handleFormSubmit,
  setPendingUploads,
  handleSubmitIntent,
  showRawLog,
  setShowRawLog,
  setUserSelectedTab,
  readyDownloadJobs,
  viewingRecentJob,
  handleSelectReadyDownload,
  handleRemoveRecentJob,
  displayedDownloads,
  handleReset,
  isBusy,
  downloadsContext,
  shareDownloadTitle,
}: WorkspaceTabsInput) {
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
              activeTab === 'setup' &&
              (state.phase !== 'idle' || showUploadingStatus) && (
                <div
                  style={{
                    display: 'flex',
                    justifyContent: 'flex-end',
                    gap: '0.5rem',
                  }}
                >
                  <button
                    type="button"
                    className="button-secondary"
                    onClick={() => handleTabChange('progress')}
                  >
                    {t.activeConversion.viewProgress} →
                  </button>
                </div>
              )
            }
          >
            {renderQueueDisplay()}
            {showActiveConversion && (
              <Suspense fallback={<ComponentFallback />}>
                <ActiveConversionBanner
                  phase={state.phase}
                  statusLabel={statusLabelOverride}
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
                  skipLabel={t.activeConversion.skip}
                  onViewProgress={() => handleTabChange('progress')}
                  onCancel={handleCancelClick}
                  onSkip={handleSkipClick}
                  canCancel={canCancelJob}
                  canSkip={canSkipJob}
                  cancelDisabled={cancelDisabled}
                  summary={state.summary}
                />
                {canShowQueueAdder && repeatConfig && (
                  <QuickQueueAdder
                    template={repeatConfig}
                    enqueue={enqueue}
                    phase={state.phase}
                    uploadFile={uploadFile}
                    onJobsAdded={handleQueueJobsAdded}
                  />
                )}
              </Suspense>
            )}
            <Suspense fallback={<ComponentFallback />}>
              <ConversionForm
                key={formVersion}
                isSubmitting={formLocked}
                onSubmit={handleFormSubmit}
                onUploadFile={uploadFile}
                onUploadStateChange={setPendingUploads}
                onSubmitIntent={handleSubmitIntent}
                currentJob={{
                  jobId: state.jobId,
                  phase: state.phase,
                  bookTitle: state.bookTitle,
                  engine: currentEngine || undefined,
                  voice: currentVoice || undefined,
                  language: currentLanguageLabel || undefined,
                  formattingCues:
                    typeof state.speakFormattingCues === 'boolean'
                      ? state.speakFormattingCues
                      : repeatConfig?.formattingCues,
                }}
              />
            </Suspense>
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
                <div
                  style={{
                    display: 'flex',
                    justifyContent: 'space-between',
                    gap: '0.5rem',
                  }}
                >
                  <button
                    type="button"
                    className="button-secondary"
                    onClick={() => handleTabChange('setup')}
                  >
                    {t.tabs.progress.backButton}
                  </button>
                  {state.phase === 'success' && (
                    <button
                      type="button"
                      className="button-secondary"
                      onClick={() => handleTabChange('downloads')}
                    >
                      {t.tabs.progress.viewDownloads}
                    </button>
                  )}
                </div>
              )
            }
          >
            {renderQueueDisplay()}
            <Suspense fallback={<ComponentFallback />}>
              <StatusPanel
                entries={state.log}
                rawLog={state.rawLog}
                phase={state.phase}
                phaseLabelOverride={statusLabelOverride}
                jobId={state.jobId}
                error={state.error}
                errorCategory={state.errorCategory}
                etaSeconds={state.etaSeconds}
                showRawLog={showRawLog}
                onToggleRawLog={() => setShowRawLog((value) => !value)}
                summary={state.summary}
                cliCommand={state.cliCommand}
                cliShell={state.cliShell}
                onCancel={state.jobId ? handleCancelClick : undefined}
                onSkip={state.jobId ? handleSkipClick : undefined}
                canCancel={canCancelJob}
                canSkip={canSkipJob}
                cancelDisabled={cancelDisabled}
                bookTitle={state.bookTitle}
                bookAuthor={state.bookAuthor}
                coverUrl={state.coverUrl}
              />
            </Suspense>
            {canShowQueueAdder && repeatConfig && (
              <Suspense fallback={<ComponentFallback />}>
                <QuickQueueAdder
                  template={repeatConfig}
                  enqueue={enqueue}
                  phase={state.phase}
                  uploadFile={uploadFile}
                  onJobsAdded={handleQueueJobsAdded}
                />
              </Suspense>
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
            footer={
              activeTab === 'downloads' && (
                <div
                  style={{
                    display: 'flex',
                    justifyContent: 'space-between',
                    gap: '0.5rem',
                  }}
                >
                  <button
                    type="button"
                    className="button-secondary"
                    onClick={() => handleTabChange('progress')}
                  >
                    {t.tabs.downloads.backButton}
                  </button>
                  {(state.phase === 'polling' || state.phase === 'submitting') && (
                    <button
                      type="button"
                      className="button-primary"
                      onClick={() => {
                        setUserSelectedTab(false);
                        handleTabChange('progress');
                      }}
                    >
                      {t.tabs.downloads.followConversion}
                    </button>
                  )}
                </div>
              )
            }
          >
            {renderQueueDisplay()}
            {readyDownloadJobs.length > 0 && (
              <Suspense fallback={<ComponentFallback />}>
                <ReadyDownloadsList
                  jobs={readyDownloadJobs}
                  activeJobId={viewingRecentJob?.jobId}
                  onSelect={handleSelectReadyDownload}
                  onRemove={handleRemoveRecentJob}
                />
              </Suspense>
            )}
            <Suspense fallback={<ComponentFallback />}>
              <DownloadsPanel
                downloads={displayedDownloads}
                phase={state.phase}
                onReset={handleReset}
                isBusy={isBusy}
                cliCommand={state.cliCommand}
                cliShell={state.cliShell}
                log={state.log}
                rawLog={state.rawLog}
                showRawLog={showRawLog}
                context={downloadsContext}
                shareTitle={shareDownloadTitle}
              />
            </Suspense>
          </Panel>
        ),
      },
    ],
    [
      activeTab,
      displayedDownloads,
      downloadsContext,
      enqueue,
      formVersion,
      handleFormSubmit,
      handleRemoveRecentJob,
      handleReset,
      handleSelectReadyDownload,
      handleTabChange,
      isBusy,
      readyDownloadJobs,
      repeatConfig,
      shareDownloadTitle,
      showRawLog,
      state.bookAuthor,
      state.bookTitle,
      state.cliCommand,
      state.cliShell,
      state.coverUrl,
      state.downloads,
      state.error,
      state.errorCategory,
      state.etaSeconds,
      state.jobId,
      state.log,
      state.phase,
      state.rawLog,
      state.summary,
      statusLabelOverride,
      setUserSelectedTab,
      t,
      viewingRecentJob,
    ],
  );

  return { tabs };
}

export type WorkspaceTabsScope = ReturnType<typeof useWorkspaceTabs>;
