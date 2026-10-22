import { conversionClient } from '../services/ConversionService';
import { VoicePreviewButton } from './VoicePreviewButton';
import type { ConversionFormScope } from './useConversionFormController';

type FormVoiceOptionsProps = Pick<
  ConversionFormScope,
  | 't'
  | 'isSubmitting'
  | 'engine'
  | 'language'
  | 'voice'
  | 'setVoice'
  | 'voiceSuggestions'
  | 'currentVoiceMultilingual'
  | 'voiceLoading'
  | 'voiceLoadFailed'
  | 'formattingCues'
  | 'setFormattingCues'
  | 'enableCharacterVoices'
  | 'setEnableCharacterVoices'
  | 'narratorVoice'
  | 'setNarratorVoice'
  | 'characterVoice'
  | 'setCharacterVoice'
>;

export function FormVoiceOptions({
  t,
  isSubmitting,
  engine,
  language,
  voice,
  setVoice,
  voiceSuggestions,
  currentVoiceMultilingual,
  voiceLoading,
  voiceLoadFailed,
  formattingCues,
  setFormattingCues,
  enableCharacterVoices,
  setEnableCharacterVoices,
  narratorVoice,
  setNarratorVoice,
  characterVoice,
  setCharacterVoice,
}: FormVoiceOptionsProps): JSX.Element {
  return (
    <>
      <fieldset className="form-row">
        <label htmlFor="voice">{t.form.voiceLabel}</label>
        <div className="voice-select-row">
          <select
            id="voice"
            name="voice"
            value={voice}
            disabled={isSubmitting || engine === 'auto'}
            onChange={(event) => setVoice(event.target.value)}
          >
            {engine === 'auto' && <option value="">{t.form.voiceAutoOption}</option>}
            {engine !== 'auto' &&
              voiceSuggestions.map((voiceInfo) => {
                const label =
                  voiceInfo.label && voiceInfo.label !== voiceInfo.name
                    ? `${voiceInfo.label} • ${voiceInfo.name}`
                    : (voiceInfo.label ?? voiceInfo.name);
                return (
                  <option key={voiceInfo.name} value={voiceInfo.name}>
                    {label} {voiceInfo.multilingual ? '🌐' : ''}
                  </option>
                );
              })}
          </select>
          {engine !== 'auto' && conversionClient.mode !== 'embedded' && (
            <VoicePreviewButton engine={engine} voice={voice} language={language} t={t} />
          )}
        </div>
        <p className="form-hint">
          {engine === 'auto'
            ? t.form.voiceAutoSelected
            : currentVoiceMultilingual
              ? `🌐 ${t.form.voiceHint} ${t.form.voiceMultilingualHint}`
              : t.form.voiceHint}
        </p>
        {voiceLoading && <p className="form-hint">{t.form.voiceLoading}</p>}
        {voiceLoadFailed && (
          <p className="form-hint form-hint--warning">{t.form.voiceLoadFailed}</p>
        )}
      </fieldset>

      <fieldset className="form-row">
        <label htmlFor="formattingCuesToggle">{t.form.formattingCuesLabel}</label>
        <label className="form-toggle" htmlFor="formattingCuesToggle">
          <input
            id="formattingCuesToggle"
            type="checkbox"
            checked={formattingCues}
            disabled={isSubmitting}
            onChange={(event) => setFormattingCues(event.target.checked)}
          />
          <span>{formattingCues ? t.form.formattingCuesOn : t.form.formattingCuesOff}</span>
        </label>
        <p className="form-hint">{t.form.formattingCuesDescription}</p>
      </fieldset>

      <fieldset className="form-row">
        <label htmlFor="characterVoicesToggle">{t.form.characterVoicesLabel}</label>
        <label className="form-toggle" htmlFor="characterVoicesToggle">
          <input
            id="characterVoicesToggle"
            type="checkbox"
            checked={enableCharacterVoices}
            disabled={isSubmitting || engine === 'auto'}
            onChange={(event) => setEnableCharacterVoices(event.target.checked)}
          />
          <span>
            {enableCharacterVoices ? t.form.characterVoicesOn : t.form.characterVoicesOff}
          </span>
        </label>
        <p className="form-hint">{t.form.characterVoicesDescription}</p>
        {enableCharacterVoices && engine !== 'auto' && (
          <div className="character-voices-grid">
            <div className="voice-select-row">
              <label htmlFor="narratorVoice">{t.form.narratorVoiceLabel}</label>
              <select
                id="narratorVoice"
                name="narrator_voice"
                value={narratorVoice}
                disabled={isSubmitting}
                onChange={(event) => setNarratorVoice(event.target.value)}
              >
                <option value="">{t.form.characterVoicesAutoOption}</option>
                {voiceSuggestions.map((voiceInfo) => {
                  const label =
                    voiceInfo.label && voiceInfo.label !== voiceInfo.name
                      ? `${voiceInfo.label} • ${voiceInfo.name}`
                      : (voiceInfo.label ?? voiceInfo.name);
                  return (
                    <option key={voiceInfo.name} value={voiceInfo.name}>
                      {label}
                    </option>
                  );
                })}
              </select>
            </div>
            <div className="voice-select-row">
              <label htmlFor="characterVoice">{t.form.characterVoiceLabel}</label>
              <select
                id="characterVoice"
                name="character_voice"
                value={characterVoice}
                disabled={isSubmitting}
                onChange={(event) => setCharacterVoice(event.target.value)}
              >
                <option value="">{t.form.characterVoicesAutoOption}</option>
                {voiceSuggestions.map((voiceInfo) => {
                  const label =
                    voiceInfo.label && voiceInfo.label !== voiceInfo.name
                      ? `${voiceInfo.label} • ${voiceInfo.name}`
                      : (voiceInfo.label ?? voiceInfo.name);
                  return (
                    <option key={voiceInfo.name} value={voiceInfo.name}>
                      {label}
                    </option>
                  );
                })}
              </select>
            </div>
          </div>
        )}
      </fieldset>
    </>
  );
}
