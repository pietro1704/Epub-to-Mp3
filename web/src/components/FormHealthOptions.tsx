import type { ConversionFormScope } from './useConversionFormController';

type FormHealthOptionsProps = Pick<
  ConversionFormScope,
  | 't'
  | 'isSubmitting'
  | 'healthCheckIntervalSeconds'
  | 'setHealthCheckIntervalSeconds'
  | 'healthCheckSlowEdgeCps'
  | 'setHealthCheckSlowEdgeCps'
  | 'healthCheckSlowCps'
  | 'setHealthCheckSlowCps'
  | 'healthCheckHighCpu'
  | 'setHealthCheckHighCpu'
  | 'healthCheckHighMem'
  | 'setHealthCheckHighMem'
  | 'healthCheckOkCpu'
  | 'setHealthCheckOkCpu'
  | 'healthCheckOkMem'
  | 'setHealthCheckOkMem'
  | 'healthCheckSlowStreak'
  | 'setHealthCheckSlowStreak'
>;

export function FormHealthOptions({
  t,
  isSubmitting,
  healthCheckIntervalSeconds,
  setHealthCheckIntervalSeconds,
  healthCheckSlowEdgeCps,
  setHealthCheckSlowEdgeCps,
  healthCheckSlowCps,
  setHealthCheckSlowCps,
  healthCheckHighCpu,
  setHealthCheckHighCpu,
  healthCheckHighMem,
  setHealthCheckHighMem,
  healthCheckOkCpu,
  setHealthCheckOkCpu,
  healthCheckOkMem,
  setHealthCheckOkMem,
  healthCheckSlowStreak,
  setHealthCheckSlowStreak,
}: FormHealthOptionsProps): JSX.Element {
  return (
    <>
      <fieldset className="form-field">
        <legend className="form-legend">{t.form.healthCheckLegend}</legend>
        <div className="form-row">
          <label htmlFor="healthCheckIntervalSeconds">{t.form.healthCheckIntervalLabel}</label>
          <input
            id="healthCheckIntervalSeconds"
            name="healthCheckIntervalSeconds"
            type="number"
            min={10}
            step={1}
            placeholder={t.form.healthCheckIntervalPlaceholder}
            value={healthCheckIntervalSeconds}
            disabled={isSubmitting}
            onChange={(event) => setHealthCheckIntervalSeconds(event.target.value)}
          />
          <p className="form-hint">{t.form.healthCheckIntervalHint}</p>
        </div>
        <div className="form-row">
          <label htmlFor="healthCheckSlowEdgeCps">{t.form.healthCheckSlowEdgeCpsLabel}</label>
          <input
            id="healthCheckSlowEdgeCps"
            name="healthCheckSlowEdgeCps"
            type="number"
            min={10}
            step={1}
            placeholder={t.form.healthCheckSlowEdgeCpsPlaceholder}
            value={healthCheckSlowEdgeCps}
            disabled={isSubmitting}
            onChange={(event) => setHealthCheckSlowEdgeCps(event.target.value)}
          />
          <p className="form-hint">{t.form.healthCheckSlowEdgeCpsHint}</p>
        </div>
        <div className="form-row">
          <label htmlFor="healthCheckSlowCps">{t.form.healthCheckSlowCpsLabel}</label>
          <input
            id="healthCheckSlowCps"
            name="healthCheckSlowCps"
            type="number"
            min={10}
            step={1}
            placeholder={t.form.healthCheckSlowCpsPlaceholder}
            value={healthCheckSlowCps}
            disabled={isSubmitting}
            onChange={(event) => setHealthCheckSlowCps(event.target.value)}
          />
          <p className="form-hint">{t.form.healthCheckSlowCpsHint}</p>
        </div>
        <div className="form-row">
          <label htmlFor="healthCheckHighCpu">{t.form.healthCheckHighCpuLabel}</label>
          <input
            id="healthCheckHighCpu"
            name="healthCheckHighCpu"
            type="number"
            min={30}
            max={100}
            step={1}
            placeholder={t.form.healthCheckHighCpuPlaceholder}
            value={healthCheckHighCpu}
            disabled={isSubmitting}
            onChange={(event) => setHealthCheckHighCpu(event.target.value)}
          />
          <p className="form-hint">{t.form.healthCheckHighCpuHint}</p>
        </div>
        <div className="form-row">
          <label htmlFor="healthCheckHighMem">{t.form.healthCheckHighMemLabel}</label>
          <input
            id="healthCheckHighMem"
            name="healthCheckHighMem"
            type="number"
            min={30}
            max={100}
            step={1}
            placeholder={t.form.healthCheckHighMemPlaceholder}
            value={healthCheckHighMem}
            disabled={isSubmitting}
            onChange={(event) => setHealthCheckHighMem(event.target.value)}
          />
          <p className="form-hint">{t.form.healthCheckHighMemHint}</p>
        </div>
        <div className="form-row">
          <label htmlFor="healthCheckOkCpu">{t.form.healthCheckOkCpuLabel}</label>
          <input
            id="healthCheckOkCpu"
            name="healthCheckOkCpu"
            type="number"
            min={10}
            max={100}
            step={1}
            placeholder={t.form.healthCheckOkCpuPlaceholder}
            value={healthCheckOkCpu}
            disabled={isSubmitting}
            onChange={(event) => setHealthCheckOkCpu(event.target.value)}
          />
          <p className="form-hint">{t.form.healthCheckOkCpuHint}</p>
        </div>
        <div className="form-row">
          <label htmlFor="healthCheckOkMem">{t.form.healthCheckOkMemLabel}</label>
          <input
            id="healthCheckOkMem"
            name="healthCheckOkMem"
            type="number"
            min={10}
            max={100}
            step={1}
            placeholder={t.form.healthCheckOkMemPlaceholder}
            value={healthCheckOkMem}
            disabled={isSubmitting}
            onChange={(event) => setHealthCheckOkMem(event.target.value)}
          />
          <p className="form-hint">{t.form.healthCheckOkMemHint}</p>
        </div>
        <div className="form-row">
          <label htmlFor="healthCheckSlowStreak">{t.form.healthCheckSlowStreakLabel}</label>
          <input
            id="healthCheckSlowStreak"
            name="healthCheckSlowStreak"
            type="number"
            min={1}
            max={6}
            step={1}
            placeholder={t.form.healthCheckSlowStreakPlaceholder}
            value={healthCheckSlowStreak}
            disabled={isSubmitting}
            onChange={(event) => setHealthCheckSlowStreak(event.target.value)}
          />
          <p className="form-hint">{t.form.healthCheckSlowStreakHint}</p>
        </div>
      </fieldset>
    </>
  );
}
