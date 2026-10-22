import type { ConversionFormScope } from './useConversionFormController';

type FormPerformanceOptionsProps = Pick<
  ConversionFormScope,
  | 't'
  | 'isSubmitting'
  | 'noParallel'
  | 'setNoParallel'
  | 'exportToIphone'
  | 'setExportToIphone'
  | 'multiEngineParallel'
  | 'setMultiEngineParallel'
  | 'maxPerformance'
  | 'setMaxPerformance'
  | 'parallelSlots'
  | 'setParallelSlots'
  | 'chapterStallSeconds'
  | 'edgeStableMode'
  | 'setChapterStallSeconds'
  | 'edgeNetworkTier'
  | 'setEdgeNetworkTier'
>;

export function FormPerformanceOptions({
  t,
  isSubmitting,
  noParallel,
  setNoParallel,
  exportToIphone,
  setExportToIphone,
  multiEngineParallel,
  setMultiEngineParallel,
  maxPerformance,
  setMaxPerformance,
  parallelSlots,
  setParallelSlots,
  chapterStallSeconds,
  edgeStableMode,
  setChapterStallSeconds,
  edgeNetworkTier,
  setEdgeNetworkTier,
}: FormPerformanceOptionsProps): JSX.Element {
  return (
    <>
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
          <span>{noParallel ? t.form.noParallelOn : t.form.noParallelOff}</span>
        </label>
        <p className="form-hint">{t.form.noParallelDescription}</p>
      </fieldset>

      <fieldset className="form-row">
        <label htmlFor="exportToIphoneToggle">{t.form.exportToIphoneLabel}</label>
        <label className="form-toggle" htmlFor="exportToIphoneToggle">
          <input
            id="exportToIphoneToggle"
            type="checkbox"
            checked={exportToIphone}
            disabled={isSubmitting}
            onChange={(event) => setExportToIphone(event.target.checked)}
          />
          <span>{exportToIphone ? t.form.exportToIphoneOn : t.form.exportToIphoneOff}</span>
        </label>
        <p className="form-hint">{t.form.exportToIphoneDescription}</p>
      </fieldset>

      <fieldset className="form-row">
        <label htmlFor="multiEngineParallelToggle">{t.form.multiEngineParallelLabel}</label>
        <label className="form-toggle" htmlFor="multiEngineParallelToggle">
          <input
            id="multiEngineParallelToggle"
            type="checkbox"
            checked={multiEngineParallel}
            disabled={isSubmitting}
            onChange={(event) => setMultiEngineParallel(event.target.checked)}
          />
          <span>
            {multiEngineParallel ? t.form.multiEngineParallelOn : t.form.multiEngineParallelOff}
          </span>
        </label>
        <p className="form-hint">{t.form.multiEngineParallelDescription}</p>
      </fieldset>

      <fieldset className="form-row">
        <label htmlFor="maxPerformanceToggle">{t.form.maxPerformanceLabel}</label>
        <label className="form-toggle" htmlFor="maxPerformanceToggle">
          <input
            id="maxPerformanceToggle"
            type="checkbox"
            checked={maxPerformance}
            disabled={isSubmitting}
            onChange={(event) => setMaxPerformance(event.target.checked)}
          />
          <span>{maxPerformance ? t.form.maxPerformanceOn : t.form.maxPerformanceOff}</span>
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
        <label htmlFor="chapterStallSeconds">{t.form.chapterStallSecondsLabel}</label>
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
        <label htmlFor="edgeNetworkTier">{t.form.edgeNetworkTierLabel}</label>
        <select
          id="edgeNetworkTier"
          name="edgeNetworkTier"
          value={edgeNetworkTier}
          disabled={isSubmitting || edgeStableMode}
          onChange={(event) =>
            setEdgeNetworkTier(event.target.value as '' | 'slow' | 'medium' | 'fast' | 'ultra')
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
    </>
  );
}
