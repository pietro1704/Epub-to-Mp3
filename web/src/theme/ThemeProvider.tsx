import { createContext, PropsWithChildren, useContext, useEffect, useMemo, useState } from 'react';

export type Theme = 'light' | 'dark';

interface ThemeContextValue {
  theme: Theme;
  prefersDarkMode: boolean;
  setTheme: (next: Theme) => void;
  toggleTheme: () => void;
}

const ThemeContext = createContext<ThemeContextValue | undefined>(undefined);

const STORAGE_KEY = 'ebook-tts-theme';

function detectSystemTheme(): Theme {
  if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') {
    return 'dark';
  }
  const query = window.matchMedia('(prefers-color-scheme: dark)');
  if (!query || typeof query.matches !== 'boolean') {
    return 'dark';
  }
  return query.matches ? 'dark' : 'light';
}

function applyThemeClass(theme: Theme): void {
  if (typeof document === 'undefined') return;
  const root = document.documentElement;
  root.classList.remove('theme-light', 'theme-dark');
  root.classList.add(`theme-${theme}`);
}

function loadStoredTheme(): Theme | null {
  if (typeof window === 'undefined') return null;
  try {
    const stored = window.localStorage.getItem(STORAGE_KEY) as Theme | null;
    if (stored === 'light' || stored === 'dark') {
      return stored;
    }
  } catch {
    /* ignore localStorage errors */
  }
  return null;
}

function persistTheme(theme: Theme): void {
  if (typeof window === 'undefined') return;
  try {
    window.localStorage.setItem(STORAGE_KEY, theme);
  } catch {
    /* ignore localStorage errors */
  }
}

export function ThemeProvider({ children }: PropsWithChildren): JSX.Element {
  const [prefersDarkMode, setPrefersDarkMode] = useState<boolean>(() => detectSystemTheme() === 'dark');
  const storedTheme = useMemo(() => loadStoredTheme(), []);
  const [isManualSelection, setIsManualSelection] = useState<boolean>(storedTheme !== null);
  const [theme, setThemeInternal] = useState<Theme>(storedTheme ?? (prefersDarkMode ? 'dark' : 'light'));

  useEffect(() => {
    applyThemeClass(theme);
  }, [theme]);

  useEffect(() => {
    if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return;
    const media = window.matchMedia('(prefers-color-scheme: dark)');
    if (!media || typeof media.addEventListener !== 'function') return;
    const listener = (event: MediaQueryListEvent) => {
      setPrefersDarkMode(event.matches);
      if (!isManualSelection) {
        setThemeInternal(event.matches ? 'dark' : 'light');
      }
    };
    media.addEventListener('change', listener);
    return () => media.removeEventListener('change', listener);
  }, [isManualSelection]);

  const setTheme = (next: Theme) => {
    setThemeInternal(next);
    setIsManualSelection(true);
    persistTheme(next);
  };

  const toggleTheme = () => {
    setThemeInternal((current) => {
      const next = current === 'dark' ? 'light' : 'dark';
      persistTheme(next);
      return next;
    });
    setIsManualSelection(true);
  };

  const value = useMemo<ThemeContextValue>(
    () => ({ theme, prefersDarkMode, setTheme, toggleTheme }),
    [theme, prefersDarkMode],
  );

  return <ThemeContext.Provider value={value}>{children}</ThemeContext.Provider>;
}

export function useTheme(): ThemeContextValue {
  const context = useContext(ThemeContext);
  if (!context) {
    throw new Error('useTheme must be used within a ThemeProvider');
  }
  return context;
}
