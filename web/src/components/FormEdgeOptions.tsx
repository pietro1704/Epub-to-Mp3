import type { ConversionFormScope } from './useConversionFormController';

type FormEdgeOptionsProps = Pick<
  ConversionFormScope,
  | 't'
  | 'isSubmitting'
  | 'noParallel'
  | 'chapterStallSeconds'
  | 'edgeStableMode'
  | 'setChapterStallSeconds'
  | 'edgeNetworkTier'
  | 'setEdgeNetworkTier'
  | 'model'
  | 'setModel'
  | 'edgeChunkChars'
  | 'setEdgeChunkChars'
  | 'edgeMaxSegmentSeconds'
  | 'setEdgeMaxSegmentSeconds'
  | 'edgeEnableParallel'
  | 'setEdgeEnableParallel'
  | 'edgeAutoTune'
  | 'setEdgeAutoTune'
  | 'setEdgeStableMode'
  | 'engineChainFallback'
  | 'setEngineChainFallback'
  | 'piperMaxProcs'
  | 'setPiperMaxProcs'
>;

export function FormEdgeOptions({
  t,
  isSubmitting,
  noParallel,
  chapterStallSeconds,
  edgeStableMode,
  setChapterStallSeconds,
  edgeNetworkTier,
  setEdgeNetworkTier,
  model,
  setModel,
  edgeChunkChars,
  setEdgeChunkChars,
  edgeMaxSegmentSeconds,
  setEdgeMaxSegmentSeconds,
  edgeEnableParallel,
  setEdgeEnableParallel,
  edgeAutoTune,
  setEdgeAutoTune,
  setEdgeStableMode,
  engineChainFallback,
  setEngineChainFallback,
  piperMaxProcs,
  setPiperMaxProcs,
}: FormEdgeOptionsProps): JSX.Element {
  return (
    <>
      <fieldset className="form-field">
        <legend className="form-legend">{t.form.engineTuningLegend}</legend>
        <div className="form-row">
          <label htmlFor="model">{t.form.modelLabel}</label>
          <input
            id="model"
            name="model"
            placeholder={t.form.modelPlaceholder}
            value={model}
            disabled={isSubmitting}
            onChange={(event) => setModel(event.target.value)}
          />
          <p className="form-hint">{t.form.modelHint}</p>
        </div>
        <div className="form-row">
          <label htmlFor="edgeChunkChars">{t.form.edgeChunkCharsLabel}</label>
          <input
            id="edgeChunkChars"
            name="edgeChunkChars"
            type="number"
            min={4000}
            placeholder={t.form.edgeChunkCharsPlaceholder}
            value={edgeChunkChars}
            disabled={isSubmitting}
            onChange={(event) => setEdgeChunkChars(event.target.value)}
          />
          <p className="form-hint">{t.form.edgeChunkCharsHint}</p>
        </div>
        <div className="form-row">
          <label htmlFor="edgeMaxSegmentSeconds">{t.form.edgeMaxSegmentSecondsLabel}</label>
          <input
            id="edgeMaxSegmentSeconds"
            name="edgeMaxSegmentSeconds"
            type="number"
            min={30}
            placeholder={t.form.edgeMaxSegmentSecondsPlaceholder}
            value={edgeMaxSegmentSeconds}
            disabled={isSubmitting}
            onChange={(event) => setEdgeMaxSegmentSeconds(event.target.value)}
          />
          <p className="form-hint">{t.form.edgeMaxSegmentSecondsHint}</p>
        </div>
        <div className="form-row">
          <label htmlFor="edgeEnableParallelToggle">{t.form.edgeEnableParallelLabel}</label>
          <label className="form-toggle" htmlFor="edgeEnableParallelToggle">
            <input
              id="edgeEnableParallelToggle"
              type="checkbox"
              checked={edgeEnableParallel}
              disabled={isSubmitting || noParallel}
              onChange={(event) => setEdgeEnableParallel(event.target.checked)}
            />
            <span>
              {edgeEnableParallel ? t.form.edgeEnableParallelOn : t.form.edgeEnableParallelOff}
            </span>
          </label>
          <p className="form-hint">{t.form.edgeEnableParallelHint}</p>
        </div>
        <div className="form-row">
          <label htmlFor="edgeAutoTuneToggle">{t.form.edgeAutoTuneLabel}</label>
          <label className="form-toggle" htmlFor="edgeAutoTuneToggle">
            <input
              id="edgeAutoTuneToggle"
              type="checkbox"
              checked={edgeAutoTune}
              disabled={isSubmitting}
              onChange={(event) => setEdgeAutoTune(event.target.checked)}
            />
            <span>{edgeAutoTune ? t.form.edgeAutoTuneOn : t.form.edgeAutoTuneOff}</span>
          </label>
          <p className="form-hint">{t.form.edgeAutoTuneHint}</p>
        </div>
        <div className="form-row">
          <label htmlFor="edgeStableModeToggle">{t.form.edgeStableModeLabel}</label>
          <label className="form-toggle" htmlFor="edgeStableModeToggle">
            <input
              id="edgeStableModeToggle"
              type="checkbox"
              checked={edgeStableMode}
              disabled={isSubmitting}
              onChange={(event) => {
                const next = event.target.checked;
                setEdgeStableMode(next);
                if (next) {
                  if (!chapterStallSeconds) {
                    setChapterStallSeconds('60');
                  }
                  if (!edgeNetworkTier) {
                    setEdgeNetworkTier('slow');
                  }
                }
              }}
            />
            <span>{edgeStableMode ? t.form.edgeStableModeOn : t.form.edgeStableModeOff}</span>
          </label>
          <p className="form-hint">{t.form.edgeStableModeHint}</p>
        </div>
        <div className="form-row">
          <label htmlFor="engineChainFallbackToggle">{t.form.engineChainFallbackLabel}</label>
          <label className="form-toggle" htmlFor="engineChainFallbackToggle">
            <input
              id="engineChainFallbackToggle"
              type="checkbox"
              checked={engineChainFallback}
              disabled={isSubmitting}
              onChange={(event) => setEngineChainFallback(event.target.checked)}
            />
            <span>
              {engineChainFallback ? t.form.engineChainFallbackOn : t.form.engineChainFallbackOff}
            </span>
          </label>
          <p className="form-hint">{t.form.engineChainFallbackHint}</p>
        </div>
        <div className="form-row">
          <label htmlFor="piperMaxProcs">{t.form.piperMaxProcsLabel}</label>
          <input
            id="piperMaxProcs"
            name="piperMaxProcs"
            type="number"
            min={1}
            placeholder={t.form.piperMaxProcsPlaceholder}
            value={piperMaxProcs}
            disabled={isSubmitting}
            onChange={(event) => setPiperMaxProcs(event.target.value)}
          />
          <p className="form-hint">{t.form.piperMaxProcsHint}</p>
        </div>
      </fieldset>
    </>
  );
}
