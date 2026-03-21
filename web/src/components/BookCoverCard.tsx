import { useState } from 'react';
import { reportUiIssue } from '../services/uiIssueMonitor';
import type { ConversionState } from '../types/conversion';

interface BookCoverCardProps {
  title?: string;
  author?: string;
  coverUrl?: string;
  phase: ConversionState['phase'];
}

function resolveStatusLabel(phase: ConversionState['phase']): string {
  switch (phase) {
    case 'submitting':
      return 'File uploaded';
    case 'polling':
      return 'Reading and converting';
    case 'success':
      return 'Conversion completed';
    case 'error':
      return 'Conversion interrupted';
    default:
      return 'Book selected';
  }
}

export default function BookCoverCard({
  title,
  author,
  coverUrl,
  phase,
}: BookCoverCardProps): JSX.Element {
  const [coverFailed, setCoverFailed] = useState(false);
  const statusLabel = resolveStatusLabel(phase);
  const resolvedTitle = title || 'Book loaded';
  const resolvedAuthor = author || 'Unknown author';
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
            onError={() => {
              setCoverFailed(true);
              reportUiIssue('cover-card', 'Book cover failed to load', {
                severity: 'info',
                details: coverUrl,
              });
            }}
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
