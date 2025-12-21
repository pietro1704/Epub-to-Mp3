import { useI18n, useTranslations } from '../i18n/I18nProvider';
import { useTheme } from '../theme/ThemeProvider';

export default function TopBar(): JSX.Element {
  const { mode: themeMode, setMode: setThemeMode } = useTheme();
  const { mode: localeMode, setLocale, setMode: setLocaleMode } = useI18n();
  const t = useTranslations();

  return (
    <div className="topbar" aria-label={t.topBar.ariaLabel}>
      <div className="topbar__group" role="group" aria-label={t.topBar.themeLabel}>
        <span className="topbar__label">{t.topBar.themeLabel}</span>
        <button
          type="button"
          className={`topbar__button${themeMode === 'auto' ? ' topbar__button--active' : ''}`}
          onClick={() => setThemeMode('auto')}
        >
          {t.topBar.themeAuto}
        </button>
        <button
          type="button"
          className={`topbar__button${themeMode === 'light' ? ' topbar__button--active' : ''}`}
          onClick={() => setThemeMode('light')}
        >
          {t.topBar.themeLight}
        </button>
        <button
          type="button"
          className={`topbar__button${themeMode === 'dark' ? ' topbar__button--active' : ''}`}
          onClick={() => setThemeMode('dark')}
        >
          {t.topBar.themeDark}
        </button>
      </div>

      <div className="topbar__group" role="group" aria-label={t.topBar.localeLabel}>
        <span className="topbar__label">{t.topBar.localeLabel}</span>
        <button
          type="button"
          className={`topbar__button${localeMode === 'auto' ? ' topbar__button--active' : ''}`}
          onClick={() => setLocaleMode('auto')}
        >
          {t.topBar.localeAuto}
        </button>
        <button
          type="button"
          className={`topbar__button${localeMode === 'pt' ? ' topbar__button--active' : ''}`}
          onClick={() => setLocale('pt')}
        >
          {t.topBar.localePortuguese}
        </button>
        <button
          type="button"
          className={`topbar__button${localeMode === 'en' ? ' topbar__button--active' : ''}`}
          onClick={() => setLocale('en')}
        >
          {t.topBar.localeEnglish}
        </button>
      </div>
    </div>
  );
}
