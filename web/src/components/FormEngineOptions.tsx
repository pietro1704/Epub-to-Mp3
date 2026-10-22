import { EngineOption } from '../types/conversion';
import { conversionClient } from '../services/ConversionService';

import type { ConversionFormScope } from './useConversionFormController';

type FormEngineOptionsProps = Pick<
  ConversionFormScope,
  | 't'
  | 'isSubmitting'
  | 'unavailableVoiceLabel'
  | 'engine'
  | 'handleEngineChange'
  | 'locale'
  | 'language'
  | 'languageOptionsList'
  | 'setLanguage'
  | 'translateLanguage'
  | 'engineMeta'
  | 'voice'
>;

export function FormEngineOptions({
  t,
  isSubmitting,
  unavailableVoiceLabel,
  engine,
  handleEngineChange,
  locale,
  language,
  languageOptionsList,
  setLanguage,
  translateLanguage,
  engineMeta,
}: FormEngineOptionsProps): JSX.Element {
  return (
    <>
      <fieldset className="form-row">
        <label htmlFor="engine">{t.form.engineLabel}</label>
        <select
          id="engine"
          name="engine"
          value={engine}
          disabled={isSubmitting}
          onChange={(event) => handleEngineChange(event.target.value as EngineOption)}
        >
          {t.form.engineOptions.map((option) => (
            <option
              key={option.value}
              value={option.value}
              disabled={conversionClient.mode === 'embedded' && option.value !== 'piper'}
            >
              {option.label}
              {conversionClient.mode === 'embedded' && option.value !== 'piper'
                ? ` — ${unavailableVoiceLabel}`
                : ''}
            </option>
          ))}
        </select>

        {/* ── Engine detail card ──────────────────────────── */}
        {engine !== 'auto' &&
          t.form.engineDetails[engine] &&
          (() => {
            const d = t.form.engineDetails[engine];
            return (
              <div className="engine-card">
                <p className="engine-card__tagline">{d.tagline}</p>
                <div className="engine-card__grid">
                  <div className="engine-card__field">
                    <span className="engine-card__label">
                      {locale === 'pt' ? 'Qualidade' : 'Quality'}
                    </span>
                    <span className="engine-card__value">{d.quality}</span>
                  </div>
                  <div className="engine-card__field">
                    <span className="engine-card__label">
                      {locale === 'pt' ? 'Velocidade' : 'Speed'}
                    </span>
                    <span className="engine-card__value">{d.speed}</span>
                  </div>
                  <div className="engine-card__field">
                    <span className="engine-card__label">
                      {locale === 'pt' ? 'Requisitos' : 'Requirements'}
                    </span>
                    <span className="engine-card__value">{d.requirements}</span>
                  </div>
                  <div className="engine-card__field">
                    <span className="engine-card__label">
                      {locale === 'pt' ? 'Idiomas' : 'Languages'}
                    </span>
                    <span className="engine-card__value">{d.languages}</span>
                  </div>
                </div>
                <div className="engine-card__best-voice">
                  <span className="engine-card__label">
                    {locale === 'pt' ? 'Melhor voz' : 'Best voice'}
                  </span>
                  <code>{d.bestVoice}</code>
                  <p className="engine-card__note">{d.bestVoiceNote}</p>
                </div>
                <div className="engine-card__pros-cons">
                  <div className="engine-card__list engine-card__list--pros">
                    {d.pros.map((pro, i) => (
                      <span key={i} className="engine-card__tag engine-card__tag--pro">
                        + {pro}
                      </span>
                    ))}
                  </div>
                  <div className="engine-card__list engine-card__list--cons">
                    {d.cons.map((con, i) => (
                      <span key={i} className="engine-card__tag engine-card__tag--con">
                        - {con}
                      </span>
                    ))}
                  </div>
                </div>
              </div>
            );
          })()}

        {engine === 'auto' && (
          <div className="engine-comparison">
            <p className="engine-comparison__title">{t.form.autoEngineComparisonTitle}</p>
            <div className="engine-comparison__table-wrap">
              <table className="engine-comparison__table">
                <thead>
                  <tr>
                    <th>{t.form.comparisonHeaders.engine}</th>
                    <th>{t.form.comparisonHeaders.quality}</th>
                    <th>{t.form.comparisonHeaders.speed}</th>
                    <th>{t.form.comparisonHeaders.languages}</th>
                    <th>{t.form.comparisonHeaders.needs}</th>
                  </tr>
                </thead>
                <tbody>
                  {(['edge', 'piper'] as const).map((eng) => {
                    const d = t.form.engineDetails[eng];
                    if (!d) return null;
                    const opt = t.form.engineOptions.find((o) => o.value === eng);
                    return (
                      <tr key={eng}>
                        <td className="engine-comparison__name">{opt?.label ?? eng}</td>
                        <td>{d.quality.split('—')[0].trim()}</td>
                        <td>{d.speed.split('—')[0].trim()}</td>
                        <td>{d.languages.split('—')[0].trim()}</td>
                        <td>{d.requirements}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
            <p className="engine-comparison__note">{t.form.autoEngineComparisonNote}</p>
          </div>
        )}
      </fieldset>

      <fieldset className="form-row">
        <label htmlFor="language">{t.form.languageLabel}</label>
        <select
          id="language"
          name="language"
          value={language}
          disabled={isSubmitting || languageOptionsList.length === 0 || engine === 'auto'}
          onChange={(event) => setLanguage(event.target.value)}
        >
          {languageOptionsList.map((code) => (
            <option key={code} value={code}>
              {translateLanguage(code)}
            </option>
          ))}
        </select>
        <p className="form-hint">
          {engine === 'auto'
            ? t.form.languageAutoDetected
            : engineMeta.autoLanguage
              ? t.form.languageNotRequired
              : t.form.languageHint}
        </p>
      </fieldset>
    </>
  );
}
