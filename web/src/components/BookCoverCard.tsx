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
      return 'Arquivo enviado';
    case 'polling':
      return 'Lendo e convertendo';
    case 'success':
      return 'Conversão concluída';
    case 'error':
      return 'Conversão interrompida';
    default:
      return 'Livro selecionado';
  }
}

export default function BookCoverCard({
  title,
  author,
  coverUrl,
  phase,
}: BookCoverCardProps): JSX.Element {
  const statusLabel = resolveStatusLabel(phase);
  const resolvedTitle = title || 'Livro carregado';
  const resolvedAuthor = author || 'Autor desconhecido';
  const altText = `Capa do livro ${resolvedTitle}`;

  return (
    <section className="cover-card" aria-label="Dados do livro selecionado">
      <div className="cover-card__image">
        {coverUrl ? (
          <img src={coverUrl} alt={altText} loading="lazy" decoding="async" />
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
