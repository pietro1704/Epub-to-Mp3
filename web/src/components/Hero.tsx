import { useTranslations } from '../i18n/I18nProvider';

export default function Hero(): JSX.Element {
  const t = useTranslations();
  const highlights = t.hero.highlights ?? [];
  return (
    <header className="hero">
      <div className="hero__copy">
        <p className="badge">{t.hero.badge}</p>
        <h1>{t.hero.title}</h1>
        <p className="hero__subtitle">{t.hero.subtitle}</p>
      </div>
      {highlights.length > 0 && (
        <div className="hero__highlights">
          {highlights.map((highlight) => (
            <article key={highlight.title} className="hero__highlight">
              <h3>{highlight.title}</h3>
              <p>{highlight.description}</p>
            </article>
          ))}
        </div>
      )}
    </header>
  );
}
