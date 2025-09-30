import { createContext, PropsWithChildren, useContext, useEffect, useMemo, useState } from 'react';
import { getTranslations, resolveLocale, type Locale, type Translations } from './translations';

interface I18nContextValue {
  locale: Locale;
  translations: Translations;
  setLocale: (locale: Locale) => void;
  cycleLocale: () => void;
}

interface I18nProviderProps extends PropsWithChildren {
  initialLocale?: Locale;
}

const I18N_STORAGE_KEY = 'ebook-tts-locale';
const I18nContext = createContext<I18nContextValue | undefined>(undefined);

function detectLocale(): Locale {
  if (typeof window === 'undefined') return 'en';
  const stored = window.localStorage.getItem(I18N_STORAGE_KEY);
  if (stored === 'en' || stored === 'pt') {
    return stored;
  }
  return resolveLocale(window.navigator.language);
}

function persistLocale(locale: Locale): void {
  if (typeof window === 'undefined') return;
  try {
    window.localStorage.setItem(I18N_STORAGE_KEY, locale);
  } catch {
    /* ignore storage errors */
  }
}

export function I18nProvider({ children, initialLocale }: I18nProviderProps): JSX.Element {
  const [locale, setLocaleState] = useState<Locale>(() => initialLocale ?? detectLocale());

  useEffect(() => {
    if (typeof document !== 'undefined') {
      document.documentElement.lang = locale === 'pt' ? 'pt-BR' : 'en-US';
    }
    persistLocale(locale);
  }, [locale]);

  const translations = useMemo(() => getTranslations(locale), [locale]);

  const setLocale = (next: Locale) => {
    setLocaleState(next);
  };

  const cycleLocale = () => {
    setLocaleState((current) => (current === 'pt' ? 'en' : 'pt'));
  };

  const value = useMemo<I18nContextValue>(
    () => ({ locale, translations, setLocale, cycleLocale }),
    [locale, translations],
  );

  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>;
}

export function useI18n(): I18nContextValue {
  const context = useContext(I18nContext);
  if (!context) {
    throw new Error('useI18n must be used within an I18nProvider');
  }
  return context;
}

export function useTranslations(): Translations {
  return useI18n().translations;
}
