import { faber, edge, system } from '../services/TtsPreferences';
import { useEffect, useState } from 'react';
import { browserSelections, loadTtsCatalog } from '../services/TtsCatalog';
import type { TtsSelection } from '../types/conversion';
import type { ConversionFormScope } from './useConversionFormController';

type FormNarrationPolicyProps = Pick<
  ConversionFormScope,
  | 'isSubmitting'
  | 'labels'
  | 'preferences'
  | 'updatePreferences'
  | 'unavailableVoiceLabel'
  | 'installModel'
  | 'modelStatus'
  | 'modelError'
  | 'usePreferences'
  | 'setUsePreferences'
  | 'engine'
  | 'manualSelection'
  | 'setCatalogSelection'
  | 'handleEngineChange'
  | 'manualSecondary'
  | 'useSecondary'
  | 'setUseSecondary'
>;

export function FormNarrationPolicy({
  isSubmitting,
  labels,
  preferences,
  updatePreferences,
  unavailableVoiceLabel,
  installModel,
  modelStatus,
  modelError,
  usePreferences,
  setUsePreferences,
  manualSelection,
  setCatalogSelection,
  handleEngineChange,
  manualSecondary,
  useSecondary,
  setUseSecondary,
}: FormNarrationPolicyProps): JSX.Element {
  const [models, setModels] = useState<TtsSelection[]>([]);
  useEffect(() => {
    let active = true;
    void loadTtsCatalog()
      .then((catalog) => {
        if (active) setModels(browserSelections(catalog));
      })
      .catch(() => undefined);
    return () => {
      active = false;
    };
  }, []);
  const primaryChoices = [preferences.primary, ...models];
  const primaryKey = (selection: TtsSelection) => selection.model_id ?? selection.engine;
  const secondaryChoices = [
    system,
    ...(preferences.secondary ? [preferences.secondary] : []),
    ...models,
    edge,
  ].filter(
    (selection, index, choices) =>
      primaryKey(selection) !== primaryKey(preferences.primary) &&
      choices.findIndex((candidate) => primaryKey(candidate) === primaryKey(selection)) === index,
  );
  return (
    <>
      <fieldset className="form-row">
        <legend>{labels.primary}</legend>
        <p>{labels.capability}</p>
        <label>
          {labels.primary}
          <select
            aria-label={labels.primary}
            value={primaryKey(preferences.primary)}
            onChange={(e) =>
              updatePreferences({
                ...preferences,
                primary: primaryChoices.find(
                  (selection) => primaryKey(selection) === e.target.value,
                ) ?? { ...faber },
                secondary: null,
              })
            }
          >
            {primaryChoices
              .filter(
                (selection, index, choices) =>
                  choices.findIndex(
                    (candidate) => primaryKey(candidate) === primaryKey(selection),
                  ) === index,
              )
              .map((selection) => (
                <option key={primaryKey(selection)} value={primaryKey(selection)}>
                  {selection.model_id === faber.model_id
                    ? 'Faber medium'
                    : (selection.model_id ?? selection.engine)}
                </option>
              ))}
            <option value="edge" disabled>
              Edge — {unavailableVoiceLabel}
            </option>
          </select>
        </label>
        <label>
          {labels.secondary}
          <select
            aria-label={labels.secondary}
            value={preferences.secondary ? primaryKey(preferences.secondary) : 'none'}
            onChange={(event) =>
              updatePreferences({
                ...preferences,
                secondary:
                  secondaryChoices.find(
                    (selection) => primaryKey(selection) === event.target.value,
                  ) ?? null,
              })
            }
          >
            <option value="none">{labels.none}</option>
            {secondaryChoices.map((selection) => (
              <option
                key={primaryKey(selection)}
                value={primaryKey(selection)}
                disabled={selection.engine === 'edge'}
              >
                {selection.engine === 'system'
                  ? labels.system
                  : selection.engine === 'edge'
                    ? `Edge — ${unavailableVoiceLabel}`
                    : selection.model_id === faber.model_id
                      ? 'Faber medium'
                      : selection.model_id}
              </option>
            ))}
          </select>
        </label>
        <label>
          <input
            type="checkbox"
            checked={preferences.allow_online_fallback}
            onChange={(e) =>
              updatePreferences({ ...preferences, allow_online_fallback: e.target.checked })
            }
          />
          {labels.online}
        </label>
        <button
          type="button"
          onClick={() => void installModel()}
          disabled={modelStatus === 'installing'}
        >
          {labels.install}
        </button>
        <p role="status">
          {modelStatus === 'idle' ? '' : modelStatus === 'error' ? modelError : labels[modelStatus]}
        </p>
        <label>
          <input
            type="checkbox"
            checked={usePreferences}
            onChange={(e) => setUsePreferences(e.target.checked)}
          />
          {labels.inherit}
        </label>
        {!usePreferences && (
          <label>
            {labels.manualVoice}
            <select
              aria-label={labels.manualVoice}
              value={primaryKey(manualSelection)}
              onChange={(event) => {
                const selection = models.find(
                  (candidate) => primaryKey(candidate) === event.target.value,
                );
                if (selection) {
                  setCatalogSelection(selection);
                  handleEngineChange(selection.engine);
                }
              }}
              disabled={isSubmitting}
            >
              {[manualSelection, ...models]
                .filter(
                  (selection, index, choices) =>
                    choices.findIndex(
                      (candidate) => primaryKey(candidate) === primaryKey(selection),
                    ) === index,
                )
                .map((selection) => (
                  <option key={primaryKey(selection)} value={primaryKey(selection)}>
                    {selection.model_id ?? selection.engine}
                  </option>
                ))}
              <option value="edge" disabled>
                Edge — {unavailableVoiceLabel}
              </option>
            </select>
          </label>
        )}
        {!usePreferences && (
          <label>
            <input
              type="checkbox"
              checked={Boolean(manualSecondary) && useSecondary}
              disabled={!manualSecondary}
              onChange={(e) => setUseSecondary(e.target.checked)}
            />
            {labels.reserve}
          </label>
        )}
      </fieldset>
    </>
  );
}
