import { useEffect, useState } from 'react';
import type { ConversionState } from '../types/conversion';
import { useTranslations } from '../i18n/I18nProvider';

interface BookCoverCardProps {
  title?: string;
  author?: string;
  coverUrl?: string;
  phase: ConversionState['phase'];
}

function resolveStatusLabel(
  phase: ConversionState['phase'],
  t: ReturnType<typeof useTranslations>,
): string {
  switch (phase) {
    case 'submitting':
      return t.status.coverPhaseSubmitting;
    case 'polling':
      return t.status.coverPhasePolling;
    case 'success':
      return t.status.coverPhaseSuccess;
    case 'error':
      return t.status.coverPhaseError;
    default:
      return t.status.coverPhaseDefault;
  }
}

export default function BookCoverCard({
  title,
  author,
  coverUrl,
  phase,
}: BookCoverCardProps): JSX.Element {
  const [coverFailed, setCoverFailed] = useState(false);
  const t = useTranslations();

  useEffect(() => {
    setCoverFailed(false);
  }, [coverUrl]);

  const statusLabel = resolveStatusLabel(phase, t);
  const resolvedTitle = title || t.status.bookFallbackTitle;
  const resolvedAuthor = author || t.status.bookFallbackAuthor;
  const altText = `Book cover ${resolvedTitle}`;

  return (
    <section className="cover-card" aria-label="Selected book data">
      <div className="cover-card__image">
        {coverUrl && !coverFailed ? (
          <img
            src={coverUrl}
            alt={altText}
            loading="lazy"
            decoding="async"
            onError={() => setCoverFailed(true)}
          />
        ) : (
          <div className="cover-card__placeholder" aria-hidden="true">
            📘
          </div>
        )}
      </div>
      <div className="cover-card__details">
        <p className="cover-card__status">{statusLabel}</p>
        <h2 className="cover-card__title cover-card__title--wrap">{resolvedTitle}</h2>
        <p className="cover-card__author">{resolvedAuthor}</p>
      </div>
    </section>
  );
}
