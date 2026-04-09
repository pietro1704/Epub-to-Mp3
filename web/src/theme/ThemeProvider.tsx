import {
  createContext,
  PropsWithChildren,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
} from "react";
import { listenTauri } from "../lib/tauri";

export type Theme = "light" | "dark";
export type ThemeMode = "light" | "dark" | "auto";

interface ThemeContextValue {
  theme: Theme;
  mode: ThemeMode;
  prefersDarkMode: boolean;
  setTheme: (next: Theme) => void;
  setMode: (mode: ThemeMode) => void;
  toggleTheme: () => void;
}

const ThemeContext = createContext<ThemeContextValue | undefined>(undefined);

const STORAGE_KEY = "ebook-tts-theme";

function detectSystemTheme(): Theme {
  if (
    typeof window === "undefined" ||
    typeof window.matchMedia !== "function"
  ) {
    return "dark";
  }
  const query = window.matchMedia("(prefers-color-scheme: dark)");
  if (!query || typeof query.matches !== "boolean") {
    return "dark";
  }
  return query.matches ? "dark" : "light";
}

function applyThemeClass(theme: Theme): void {
  if (typeof document === "undefined") return;
  const root = document.documentElement;
  root.classList.remove("theme-light", "theme-dark");
  root.classList.add(`theme-${theme}`);
}

function loadStoredMode(): ThemeMode | null {
  if (typeof window === "undefined") return null;
  try {
    const stored = window.localStorage.getItem(STORAGE_KEY) as ThemeMode | null;
    if (stored === "light" || stored === "dark" || stored === "auto") {
      return stored;
    }
  } catch {
    /* ignore localStorage errors */
  }
  return null;
}

function persistMode(mode: ThemeMode): void {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.setItem(STORAGE_KEY, mode);
  } catch {
    /* ignore localStorage errors */
  }
}

export function ThemeProvider({ children }: PropsWithChildren): JSX.Element {
  const [prefersDarkMode, setPrefersDarkMode] = useState<boolean>(
    () => detectSystemTheme() === "dark",
  );
  const storedMode = useMemo(() => loadStoredMode(), []);
  const [mode, setModeInternal] = useState<ThemeMode>(storedMode ?? "auto");
  const [theme, setThemeInternal] = useState<Theme>(() => {
    if (storedMode === "auto" || storedMode === null) {
      return prefersDarkMode ? "dark" : "light";
    }
    return storedMode;
  });

  useEffect(() => {
    applyThemeClass(theme);
  }, [theme]);

  useEffect(() => {
    if (
      typeof window === "undefined" ||
      typeof window.matchMedia !== "function"
    )
      return;
    const media = window.matchMedia("(prefers-color-scheme: dark)");
    if (!media || typeof media.addEventListener !== "function") return;
    const listener = (event: MediaQueryListEvent) => {
      setPrefersDarkMode(event.matches);
      if (mode === "auto") {
        setThemeInternal(event.matches ? "dark" : "light");
      }
    };
    media.addEventListener("change", listener);
    return () => media.removeEventListener("change", listener);
  }, [mode]);

  const setMode = useCallback(
    (newMode: ThemeMode) => {
      setModeInternal(newMode);
      persistMode(newMode);
      if (newMode === "auto") {
        setThemeInternal(prefersDarkMode ? "dark" : "light");
      } else {
        setThemeInternal(newMode);
      }
    },
    [prefersDarkMode],
  );

  // Listen for native menu theme changes
  useEffect(() => {
    let unlisten: (() => void) | undefined;
    listenTauri("tauri-set-theme", (payload) => {
      const value = payload as string;
      if (value === "auto" || value === "light" || value === "dark") {
        setMode(value);
      }
    }).then((fn) => {
      unlisten = fn;
    });
    return () => unlisten?.();
  }, [setMode]);

  const setTheme = useCallback((next: Theme) => {
    setModeInternal(next);
    setThemeInternal(next);
    persistMode(next);
  }, []);

  const toggleTheme = useCallback(() => {
    const next = theme === "dark" ? "light" : "dark";
    setMode(next);
  }, [theme, setMode]);

  const value = useMemo<ThemeContextValue>(
    () => ({ theme, mode, prefersDarkMode, setTheme, setMode, toggleTheme }),
    [theme, mode, prefersDarkMode, setTheme, setMode, toggleTheme],
  );

  return (
    <ThemeContext.Provider value={value}>{children}</ThemeContext.Provider>
  );
}

export function useTheme(): ThemeContextValue {
  const context = useContext(ThemeContext);
  if (!context) {
    throw new Error("useTheme must be used within a ThemeProvider");
  }
  return context;
}
