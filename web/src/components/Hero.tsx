import { useTranslations } from '../i18n/I18nProvider';

export default function Hero(): JSX.Element {
  const t = useTranslations();
  return (
    <header className="hero">
      <p className="badge">{t.hero.badge}</p>
      <h1>{t.hero.title}</h1>
      <p className="hero__subtitle">{t.hero.subtitle}</p>
    </header>
  );
}
