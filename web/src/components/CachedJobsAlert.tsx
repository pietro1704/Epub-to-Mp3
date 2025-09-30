interface CachedJob {
  jobId: string;
  fileName: string;
  timestamp: number;
}

interface CachedJobsAlertProps {
  cachedJobs: CachedJob[];
  onResume: (jobId: string) => void;
  onDismiss: () => void;
}

export default function CachedJobsAlert({ cachedJobs, onResume, onDismiss }: CachedJobsAlertProps): JSX.Element | null {
  if (cachedJobs.length === 0) return null;

  const formatTime = (timestamp: number): string => {
    const now = Date.now();
    const diff = now - timestamp;
    const minutes = Math.floor(diff / 60000);
    const hours = Math.floor(minutes / 60);
    const days = Math.floor(hours / 24);

    if (days > 0) return `há ${days} dia${days > 1 ? 's' : ''}`;
    if (hours > 0) return `há ${hours} hora${hours > 1 ? 's' : ''}`;
    if (minutes > 0) return `há ${minutes} minuto${minutes > 1 ? 's' : ''}`;
    return 'agora mesmo';
  };

  return (
    <div className="cached-jobs-alert">
      <div className="cached-jobs-alert__header">
        <h3>🔄 Conversões Interrompidas</h3>
        <button type="button" className="cached-jobs-alert__close" onClick={onDismiss} aria-label="Fechar">
          ✕
        </button>
      </div>
      <p className="cached-jobs-alert__message">
        {cachedJobs.length === 1
          ? 'Encontramos 1 conversão que foi interrompida. Deseja retomar?'
          : `Encontramos ${cachedJobs.length} conversões que foram interrompidas. Deseja retomar alguma?`}
      </p>
      <ul className="cached-jobs-alert__list">
        {cachedJobs.map((job) => (
          <li key={job.jobId} className="cached-jobs-alert__item">
            <div className="cached-jobs-alert__info">
              <span className="cached-jobs-alert__filename">📄 {job.fileName}</span>
              <span className="cached-jobs-alert__time">{formatTime(job.timestamp)}</span>
            </div>
            <button
              type="button"
              className="cached-jobs-alert__resume"
              onClick={() => onResume(job.jobId)}
            >
              Retomar
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}
