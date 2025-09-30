import { useI18n, useTranslations } from '../i18n/I18nProvider';
import { useTheme } from '../theme/ThemeProvider';

export default function TopBar(): JSX.Element {
  const { theme, setTheme } = useTheme();
  const { locale, setLocale } = useI18n();
  const t = useTranslations();

  return (
    <div className="topbar" aria-label={t.topBar.ariaLabel}>
      <div className="topbar__group" role="group" aria-label={t.topBar.themeLabel}>
        <span className="topbar__label">{t.topBar.themeLabel}</span>
        <button
          type="button"
          className={`topbar__button${theme === 'light' ? ' topbar__button--active' : ''}`}
          onClick={() => setTheme('light')}
        >
          {t.topBar.themeLight}
        </button>
        <button
          type="button"
          className={`topbar__button${theme === 'dark' ? ' topbar__button--active' : ''}`}
          onClick={() => setTheme('dark')}
        >
          {t.topBar.themeDark}
        </button>
      </div>

      <div className="topbar__group" role="group" aria-label={t.topBar.localeLabel}>
        <span className="topbar__label">{t.topBar.localeLabel}</span>
        <button
          type="button"
          className={`topbar__button${locale === 'pt' ? ' topbar__button--active' : ''}`}
          onClick={() => setLocale('pt')}
        >
          {t.topBar.localePortuguese}
        </button>
        <button
          type="button"
          className={`topbar__button${locale === 'en' ? ' topbar__button--active' : ''}`}
          onClick={() => setLocale('en')}
        >
          {t.topBar.localeEnglish}
        </button>
      </div>
    </div>
  );
}
