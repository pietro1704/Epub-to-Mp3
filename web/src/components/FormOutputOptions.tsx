import type { ConversionFormScope } from './useConversionFormController';

type FormOutputOptionsProps = Pick<
  ConversionFormScope,
  | 't'
  | 'isSubmitting'
  | 'useLanguageDetection'
  | 'setUseLanguageDetection'
  | 'prioritizePrimaryLanguage'
  | 'setPrioritizePrimaryLanguage'
>;

export function FormOutputOptions({
  t,
  isSubmitting,
  useLanguageDetection,
  setUseLanguageDetection,
  prioritizePrimaryLanguage,
  setPrioritizePrimaryLanguage,
}: FormOutputOptionsProps): JSX.Element {
  return (
    <>
      <fieldset className="form-field">
        <legend className="form-legend">{t.form.languageDetectionLegend}</legend>
        <div className="form-row">
          <label htmlFor="useLanguageDetectionToggle">{t.form.languageDetectionLabel}</label>
          <label className="form-toggle" htmlFor="useLanguageDetectionToggle">
            <input
              id="useLanguageDetectionToggle"
              type="checkbox"
              checked={useLanguageDetection}
              disabled={isSubmitting}
              onChange={(event) => setUseLanguageDetection(event.target.checked)}
            />
            <span>
              {useLanguageDetection ? t.form.languageDetectionOn : t.form.languageDetectionOff}
            </span>
          </label>
          <p className="form-hint">{t.form.languageDetectionDescription}</p>
        </div>
        <div className="form-row">
          <label htmlFor="prioritizePrimaryLanguageToggle">
            {t.form.prioritizePrimaryLanguageLabel}
          </label>
          <label className="form-toggle" htmlFor="prioritizePrimaryLanguageToggle">
            <input
              id="prioritizePrimaryLanguageToggle"
              type="checkbox"
              checked={prioritizePrimaryLanguage}
              disabled={isSubmitting}
              onChange={(event) => setPrioritizePrimaryLanguage(event.target.checked)}
            />
            <span>
              {prioritizePrimaryLanguage
                ? t.form.prioritizePrimaryLanguageOn
                : t.form.prioritizePrimaryLanguageOff}
            </span>
          </label>
          <p className="form-hint">{t.form.prioritizePrimaryLanguageDescription}</p>
        </div>
      </fieldset>
    </>
  );
}
