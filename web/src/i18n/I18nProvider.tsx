import { createContext, PropsWithChildren, useContext, useEffect, useMemo, useState } from 'react';
import { getTranslations, resolveLocale, type Locale, type Translations } from './translations';

export type LocaleMode = 'pt' | 'en' | 'auto';

interface I18nContextValue {
  locale: Locale;
  mode: LocaleMode;
  translations: Translations;
  setLocale: (locale: Locale) => void;
  setMode: (mode: LocaleMode) => void;
  cycleLocale: () => void;
}

interface I18nProviderProps extends PropsWithChildren {
  initialLocale?: Locale;
}

const I18N_STORAGE_KEY = 'ebook-tts-locale';
const I18nContext = createContext<I18nContextValue | undefined>(undefined);

function detectBrowserLocale(): Locale {
  if (typeof window === 'undefined') return 'en';
  return resolveLocale(window.navigator.language);
}

function loadStoredMode(): LocaleMode | null {
  if (typeof window === 'undefined') return null;
  try {
    const stored = window.localStorage.getItem(I18N_STORAGE_KEY);
    if (stored === 'en' || stored === 'pt' || stored === 'auto') {
      return stored as LocaleMode;
    }
  } catch {
    /* ignore storage errors */
  }
  return null;
}

function persistMode(mode: LocaleMode): void {
  if (typeof window === 'undefined') return;
  try {
    window.localStorage.setItem(I18N_STORAGE_KEY, mode);
  } catch {
    /* ignore storage errors */
  }
}

export function I18nProvider({ children, initialLocale }: I18nProviderProps): JSX.Element {
  const browserLocale = useMemo(() => detectBrowserLocale(), []);
  const storedMode = useMemo(() => loadStoredMode(), []);
  const [mode, setModeInternal] = useState<LocaleMode>(storedMode ?? 'auto');
  const [locale, setLocaleState] = useState<Locale>(() => {
    if (initialLocale) return initialLocale;
    if (storedMode === 'auto' || storedMode === null) {
      return browserLocale;
    }
    return storedMode;
  });

  useEffect(() => {
    if (typeof document !== 'undefined') {
      document.documentElement.lang = locale === 'pt' ? 'pt-BR' : 'en-US';
    }
  }, [locale]);

  const translations = useMemo(() => getTranslations(locale), [locale]);

  const setMode = (newMode: LocaleMode) => {
    setModeInternal(newMode);
    persistMode(newMode);
    if (newMode === 'auto') {
      setLocaleState(browserLocale);
    } else {
      setLocaleState(newMode);
    }
  };

  const setLocale = (next: Locale) => {
    setModeInternal(next);
    setLocaleState(next);
    persistMode(next);
  };

  const cycleLocale = () => {
    const next = locale === 'pt' ? 'en' : 'pt';
    setMode(next);
  };

  const value = useMemo<I18nContextValue>(
    () => ({ locale, mode, translations, setLocale, setMode, cycleLocale }),
    [locale, mode, translations, browserLocale],
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
