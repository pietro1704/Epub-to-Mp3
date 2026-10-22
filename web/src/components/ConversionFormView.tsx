import type { ConversionFormScope } from './useConversionFormController';
import { FormBookSource } from './FormBookSource';
import { FormNarrationPolicy } from './FormNarrationPolicy';
import { FormEngineOptions } from './FormEngineOptions';
import { FormVoiceOptions } from './FormVoiceOptions';
import { FormPerformanceOptions } from './FormPerformanceOptions';
import { FormEdgeOptions } from './FormEdgeOptions';
import { FormAudioOptions } from './FormAudioOptions';
import { FormOutputOptions } from './FormOutputOptions';
import { FormHealthOptions } from './FormHealthOptions';
import { FormChapterSelection } from './FormChapterSelection';

export function ConversionFormView(scope: ConversionFormScope): JSX.Element {
  const {
    isDragOver,
    handleSubmit,
    dragCounter,
    setIsDragOver,
    addFilesToQueue,
    folderInputRef,
    t,
    isSubmitting,
    engine,
    showMissingFileError,
    estimatedDuration,
    engineEstimates,
    disableSubmit,
    uploadPromisesRef,
  } = scope;

  return (
    <form
      className={`conversion-form${isDragOver ? ' conversion-form--drag-over' : ''}`}
      onSubmit={handleSubmit}
      onDragEnter={(e) => {
        e.preventDefault();
        dragCounter.current++;
        if (e.dataTransfer.types.includes('Files')) setIsDragOver(true);
      }}
      onDragOver={(e) => e.preventDefault()}
      onDragLeave={(e) => {
        e.preventDefault();
        dragCounter.current--;
        if (dragCounter.current <= 0) {
          dragCounter.current = 0;
          setIsDragOver(false);
        }
      }}
      onDrop={(e) => {
        e.preventDefault();
        dragCounter.current = 0;
        setIsDragOver(false);
        const files = e.dataTransfer.files;
        if (files && files.length > 0) {
          addFilesToQueue(files);
        }
      }}
    >
      <input
        ref={folderInputRef}
        type="file"
        multiple
        style={{ display: 'none' }}
        onChange={(event) => {
          const files = event.target.files;
          if (files && files.length > 0) {
            addFilesToQueue(files);
            event.target.value = '';
          }
        }}
      />
      <FormBookSource {...scope} />

      <FormNarrationPolicy {...scope} />

      <details className="form-advanced">
        <summary>{t.form.advancedSummary}</summary>
        <div className="form-advanced__content">
          <FormEngineOptions {...scope} />

          <FormVoiceOptions {...scope} />

          <FormPerformanceOptions {...scope} />

          <FormEdgeOptions {...scope} />

          <FormAudioOptions {...scope} />

          <FormOutputOptions {...scope} />

          <FormHealthOptions {...scope} />

          <FormChapterSelection {...scope} />
        </div>
      </details>

      {showMissingFileError && (
        <p role="alert" className="form-error">
          {t.form.errorNoFile}
        </p>
      )}

      {estimatedDuration && !isSubmitting && (
        <div className="form-estimate">
          <p className="form-estimate__primary">{t.form.estimatedDuration(estimatedDuration)}</p>
          {engineEstimates && Object.keys(engineEstimates).length > 1 && (
            <div className="form-estimate__comparison">
              {(['edge', 'piper'] as const)
                .filter((eng) => engineEstimates[eng])
                .map((eng) => {
                  const est = engineEstimates[eng];
                  const isActive = engine === eng || (engine === 'auto' && eng === 'edge');
                  const opt = t.form.engineOptions.find((o) => o.value === eng);
                  return (
                    <div
                      key={eng}
                      className={`form-estimate__engine ${isActive ? 'form-estimate__engine--active' : ''}`}
                    >
                      <span className="form-estimate__engine-name">{opt?.label ?? eng}</span>
                      <span className="form-estimate__engine-time">
                        {est.estimated_duration_formatted}
                      </span>
                      <span className="form-estimate__engine-size">
                        {est.estimated_output_mb} MB
                      </span>
                    </div>
                  );
                })}
            </div>
          )}
        </div>
      )}
      <button type="submit" disabled={disableSubmit} className="form-submit">
        {isSubmitting || Object.keys(uploadPromisesRef.current).length > 0
          ? t.form.submitBusy
          : t.form.submitIdle}
      </button>
    </form>
  );
}
