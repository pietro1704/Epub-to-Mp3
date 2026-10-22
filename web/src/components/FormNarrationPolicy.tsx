import { faber, edge, system } from '../services/TtsPreferences';
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
  engine,
  handleEngineChange,
  manualSecondary,
  useSecondary,
  setUseSecondary,
}: FormNarrationPolicyProps): JSX.Element {
  return (
    <>
      <fieldset className="form-row">
        <legend>{labels.primary}</legend>
        <p>{labels.capability}</p>
        <label>
          {labels.primary}
          <select
            aria-label={labels.primary}
            value={preferences.primary.engine}
            onChange={(e) =>
              updatePreferences({
                ...preferences,
                primary: e.target.value === 'piper' ? { ...faber } : { ...edge },
                secondary: null,
              })
            }
          >
            <option value="piper">Faber medium</option>
            <option value="edge" disabled>
              Edge — {unavailableVoiceLabel}
            </option>
          </select>
        </label>
        <label>
          {labels.secondary}
          <select
            aria-label={labels.secondary}
            value={preferences.secondary?.engine ?? 'none'}
            onChange={(e) =>
              updatePreferences({
                ...preferences,
                secondary:
                  e.target.value === 'none'
                    ? null
                    : e.target.value === 'system'
                      ? { ...system }
                      : e.target.value === 'edge'
                        ? { ...edge }
                        : { ...faber },
              })
            }
          >
            <option value="none">{labels.none}</option>
            <option value="system">{labels.system}</option>
            <option
              value={preferences.primary.engine === 'piper' ? 'edge' : 'piper'}
              disabled={preferences.primary.engine === 'piper'}
            >
              {preferences.primary.engine === 'piper'
                ? `Edge — ${unavailableVoiceLabel}`
                : 'Faber medium'}
            </option>
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
              value={engine}
              onChange={(event) => handleEngineChange(event.target.value)}
              disabled={isSubmitting}
            >
              <option value="piper">Faber medium</option>
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
