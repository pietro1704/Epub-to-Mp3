import type { ConversionFormScope } from './useConversionFormController';

type FormAudioOptionsProps = Pick<
  ConversionFormScope,
  | 't'
  | 'isSubmitting'
  | 'bitrate'
  | 'setBitrate'
  | 'sampleRate'
  | 'setSampleRate'
  | 'channels'
  | 'setChannels'
  | 'verbose'
  | 'setVerbose'
  | 'clearCache'
  | 'setClearCache'
  | 'forceReprocess'
  | 'setForceReprocess'
  | 'filterChapters'
  | 'setFilterChapters'
>;

export function FormAudioOptions({
  t,
  isSubmitting,
  bitrate,
  setBitrate,
  sampleRate,
  setSampleRate,
  channels,
  setChannels,
  verbose,
  setVerbose,
  clearCache,
  setClearCache,
  forceReprocess,
  setForceReprocess,
  filterChapters,
  setFilterChapters,
}: FormAudioOptionsProps): JSX.Element {
  return (
    <>
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
            <span>{clearCache ? t.form.clearCacheOn : t.form.clearCacheOff}</span>
          </label>
          <p className="form-hint">{t.form.clearCacheDescription}</p>
        </div>
        <div className="form-row">
          <label htmlFor="forceReprocessToggle">{t.form.forceReprocessLabel}</label>
          <label className="form-toggle" htmlFor="forceReprocessToggle">
            <input
              id="forceReprocessToggle"
              type="checkbox"
              checked={forceReprocess}
              disabled={isSubmitting}
              onChange={(event) => setForceReprocess(event.target.checked)}
            />
            <span>{forceReprocess ? t.form.forceReprocessOn : t.form.forceReprocessOff}</span>
          </label>
          <p className="form-hint">{t.form.forceReprocessDescription}</p>
        </div>
        <div className="form-row">
          <label htmlFor="filterChaptersToggle">{t.form.filterChaptersLabel}</label>
          <label className="form-toggle" htmlFor="filterChaptersToggle">
            <input
              id="filterChaptersToggle"
              type="checkbox"
              checked={filterChapters}
              disabled={isSubmitting}
              onChange={(event) => setFilterChapters(event.target.checked)}
            />
            <span>{filterChapters ? t.form.filterChaptersOn : t.form.filterChaptersOff}</span>
          </label>
          <p className="form-hint">{t.form.filterChaptersDescription}</p>
        </div>
      </fieldset>
    </>
  );
}
