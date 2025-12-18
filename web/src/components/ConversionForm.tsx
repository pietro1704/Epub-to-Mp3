import { FormEvent, useMemo, useState } from 'react';
import { useTranslations } from '../i18n/I18nProvider';
import { ConversionFormValues, EngineOption, FootnoteMode } from '../types/conversion';

interface ConversionFormProps {
  isSubmitting: boolean;
  onSubmit: (values: ConversionFormValues) => Promise<void> | void;
}

interface VoiceInfo {
  name: string;
  multilingual: boolean;
}

const VOICE_SUGGESTIONS: Record<string, VoiceInfo[]> = {
  edge: [
    { name: 'pt-BR-ThalitaNeural', multilingual: true },
    { name: 'pt-BR-FranciscaNeural', multilingual: false },
    { name: 'en-US-JennyNeural', multilingual: false },
    { name: 'es-ES-ElviraNeural', multilingual: false },
  ],
  piper: [
    { name: 'pt_BR-faber-medium.onnx', multilingual: false },
    { name: 'en_US-lessac-medium.onnx', multilingual: false },
  ],
  coqui: [
    { name: 'tts_models/pt/cv/vits', multilingual: false },
    { name: 'tts_models/multilingual/multi-dataset/xtts_v2', multilingual: true },
  ],
  auto: [
    { name: 'tts_models/pt/cv/vits', multilingual: false },
    { name: 'pt-BR-ThalitaNeural', multilingual: true },
  ],
};

type KnownEngine = 'edge' | 'piper' | 'coqui' | 'auto';

interface EngineInsights {
  defaultVoice: string;
  multiLingual: boolean;
  autoLanguage: boolean;
  languages: string[];
}

const ENGINE_INFO: Record<KnownEngine, EngineInsights> = {
  edge: {
    defaultVoice: 'pt-BR-ThalitaNeural',
    multiLingual: true,
    autoLanguage: true,
    languages: ['auto'],
  },
  piper: {
    defaultVoice: 'pt_BR-faber-medium.onnx',
    multiLingual: false,
    autoLanguage: false,
    languages: ['pt', 'en'],
  },
  coqui: {
    defaultVoice: 'tts_models/pt/cv/vits',
    multiLingual: true,
    autoLanguage: false,
    languages: ['pt', 'en', 'es', 'fr', 'de'],
  },
  auto: {
    defaultVoice: '',
    multiLingual: true,
    autoLanguage: true,
    languages: ['auto'],
  },
};

const FALLBACK_ENGINE_META: EngineInsights = {
  defaultVoice: '',
  multiLingual: true,
  autoLanguage: true,
  languages: ['auto'],
};

function getEngineMeta(engine: EngineOption): EngineInsights {
  if ((ENGINE_INFO as Record<string, EngineInsights>)[engine]) {
    return (ENGINE_INFO as Record<string, EngineInsights>)[engine];
  }
  return FALLBACK_ENGINE_META;
}

export default function ConversionForm({ isSubmitting, onSubmit }: ConversionFormProps): JSX.Element {
  const t = useTranslations();
  const initialEngine: EngineOption = 'auto';
  const initialMeta = getEngineMeta(initialEngine);
  const [selectedFile, setSelectedFile] = useState<File | null>(null);
  const [engine, setEngine] = useState<EngineOption>(initialEngine);
  const [voice, setVoice] = useState(initialMeta.defaultVoice);
  const [chapters, setChapters] = useState('');
  const [priority, setPriority] = useState('');
  const [footnoteMode, setFootnoteMode] = useState<FootnoteMode>('inline');
  const [language, setLanguage] = useState<string>(initialMeta.autoLanguage ? 'auto' : initialMeta.languages[0] ?? '');
  const [showMissingFileError, setShowMissingFileError] = useState(false);

  const engineMeta = useMemo<EngineInsights>(() => getEngineMeta(engine), [engine]);
  const voiceSuggestionListId = useMemo(() => `voices-${engine}`, [engine]);
  const voiceSuggestions = useMemo(() => {
    const voices: VoiceInfo[] = [];
    const seenNames = new Set<string>();

    if (engineMeta.defaultVoice && !seenNames.has(engineMeta.defaultVoice)) {
      const defaultInfo = (VOICE_SUGGESTIONS[engine] ?? []).find(v => v.name === engineMeta.defaultVoice);
      voices.push(defaultInfo ?? { name: engineMeta.defaultVoice, multilingual: false });
      seenNames.add(engineMeta.defaultVoice);
    }

    (VOICE_SUGGESTIONS[engine] ?? []).forEach((voiceInfo) => {
      if (!seenNames.has(voiceInfo.name)) {
        voices.push(voiceInfo);
        seenNames.add(voiceInfo.name);
      }
    });

    return voices;
  }, [engine, engineMeta.defaultVoice]);

  const currentVoiceMultilingual = useMemo(() => {
    return voiceSuggestions.find(v => v.name === voice)?.multilingual ?? false;
  }, [voiceSuggestions, voice]);

  const handleSubmit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!selectedFile) {
      setShowMissingFileError(true);
      return;
    }

    setShowMissingFileError(false);
    await onSubmit({
      file: selectedFile,
      engine,
      voice: voice || undefined,
      chapters: chapters || undefined,
      priority: priority || undefined,
      footnoteMode,
      language: engineMeta.autoLanguage || !language || language === 'auto' ? undefined : language,
    });
  };

  const translateLanguage = (code: string): string => {
    return t.form.languageOptions[code] ?? code.toUpperCase();
  };

  const handleEngineChange = (nextEngine: EngineOption) => {
    setEngine(nextEngine);
    const meta = getEngineMeta(nextEngine);
    setVoice(meta.defaultVoice);
    setLanguage(meta.autoLanguage ? 'auto' : meta.languages[0] ?? '');
  };

  const handleUseSample = async () => {
    try {
      const response = await fetch('/sample.epub');
      const blob = await response.blob();
      const file = new File([blob], 'sample.epub', { type: 'application/epub+zip' });
      setSelectedFile(file);
      setShowMissingFileError(false);
    } catch (error) {
      console.error('Failed to load sample book:', error);
    }
  };

  return (
    <form className="conversion-form" onSubmit={handleSubmit}>
      <fieldset className="form-field">
        <label htmlFor="file">{t.form.fileLabel}</label>
        <div style={{ display: 'flex', gap: '0.5rem', alignItems: 'center' }}>
          <input
            id="file"
            name="file"
            type="file"
            accept="application/epub+zip,application/pdf"
            disabled={isSubmitting}
            onChange={(event) => {
              const file = event.target.files?.[0] ?? null;
              setSelectedFile(file);
              if (file) {
                setShowMissingFileError(false);
              }
            }}
            style={{ flex: 1 }}
          />
          <button
            type="button"
            onClick={handleUseSample}
            disabled={isSubmitting}
            className="button-secondary"
            style={{ whiteSpace: 'nowrap' }}
          >
            {t.form.useSampleButton}
          </button>
        </div>
        {selectedFile && (
          <p className="form-hint form-hint--filename" title={selectedFile.name}>
            <span aria-hidden="true">📄</span>
            <span className="form-hint__filename">{selectedFile.name}</span>
          </p>
        )}
        <p className="form-hint">{t.form.fileHint}</p>
      </fieldset>

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
            <option key={option.value} value={option.value}>
              {option.label}
            </option>
          ))}
        </select>
        <p className="form-hint">{t.form.engineOptions.find((option) => option.value === engine)?.help}</p>
        <div className="engine-insight">
          <div className="engine-insight__item">
            <span className="engine-insight__label">{t.form.defaultVoiceLabel}</span>
            <code className="engine-insight__value">{engineMeta.defaultVoice}</code>
          </div>
          <div className="engine-insight__item">
            <span className="engine-insight__label">{t.form.multilingualSupportLabel}</span>
            <span className="engine-insight__value">
              {engineMeta.multiLingual ? t.form.multilingualYes : t.form.multilingualNo}
            </span>
          </div>
          <div className="engine-insight__item">
            <span className="engine-insight__label">{engineMeta.autoLanguage ? t.form.autoLanguageLabel : t.form.manualLanguageLabel}</span>
          </div>
          {!engineMeta.autoLanguage && engineMeta.languages.length > 0 && (
            <div className="engine-insight__languages">
              <span className="engine-insight__label">{t.form.availableLanguagesLabel}:</span>
              <ul>
                {engineMeta.languages.map((code) => (
                  <li key={code}>{translateLanguage(code)}</li>
                ))}
              </ul>
            </div>
          )}
        </div>
      </fieldset>

      <fieldset className="form-row">
        <label htmlFor="voice">{t.form.voiceLabel}</label>
        <select
          id="voice"
          name="voice"
          value={voice}
          disabled={isSubmitting}
          onChange={(event) => setVoice(event.target.value)}
        >
          {voiceSuggestions.map((voiceInfo) => (
            <option key={voiceInfo.name} value={voiceInfo.name}>
              {voiceInfo.name} {voiceInfo.multilingual ? '🌐' : ''}
            </option>
          ))}
        </select>
        <p className="form-hint">
          {currentVoiceMultilingual && '🌐 '}
          {t.form.voiceHint}
          {currentVoiceMultilingual && ` ${t.form.voiceMultilingualHint}`}
        </p>
      </fieldset>

      {engineMeta.autoLanguage ? (
        <p className="form-hint">{t.form.languageNotRequired}</p>
      ) : (
        <fieldset className="form-row">
          <label htmlFor="language">{t.form.languageLabel}</label>
          <select
            id="language"
            name="language"
            value={language}
            disabled={isSubmitting}
            onChange={(event) => setLanguage(event.target.value)}
          >
            {engineMeta.languages.map((code) => (
              <option key={code} value={code}>
                {translateLanguage(code)}
              </option>
            ))}
          </select>
          <p className="form-hint">{t.form.languageHint}</p>
        </fieldset>
      )}

      <fieldset className="form-row">
        <label htmlFor="chapters">{t.form.chaptersLabel}</label>
        <input
          id="chapters"
          name="chapters"
          placeholder={t.form.chaptersPlaceholder}
          value={chapters}
          disabled={isSubmitting}
          onChange={(event) => setChapters(event.target.value)}
        />
        <p className="form-hint">{t.form.chaptersHint}</p>
      </fieldset>

      <fieldset className="form-row">
        <label htmlFor="priority">{t.form.priorityLabel}</label>
        <input
          id="priority"
          name="priority"
          placeholder={t.form.priorityPlaceholder}
          value={priority}
          disabled={isSubmitting}
          onChange={(event) => setPriority(event.target.value)}
        />
        <p className="form-hint">{t.form.priorityHint}</p>
      </fieldset>

      <fieldset className="form-field">
        <legend className="form-legend">{t.form.footnoteLegend}</legend>
        <div className="segmented-list">
          {t.form.footnoteOptions.map((option) => {
            const inputId = `footnote-${option.value}`;
            return (
              <label key={option.value} className="segmented-list__item" htmlFor={inputId}>
                <input
                  type="radio"
                  id={inputId}
                  name="footnoteMode"
                  value={option.value}
                  checked={footnoteMode === option.value}
                  disabled={isSubmitting}
                  onChange={() => setFootnoteMode(option.value)}
                />
                <span className="segmented-list__content">
                  <span className="segmented-list__title">{option.title}</span>
                  <span className="segmented-list__description">{option.description}</span>
                </span>
              </label>
            );
          })}
        </div>
      </fieldset>

      {showMissingFileError && (
        <p role="alert" className="form-error">
          {t.form.errorNoFile}
        </p>
      )}

      <button type="submit" disabled={isSubmitting} className="form-submit">
        {isSubmitting ? t.form.submitBusy : t.form.submitIdle}
      </button>
    </form>
  );
}
