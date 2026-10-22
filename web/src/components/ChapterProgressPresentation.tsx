import { ChapterProgressEntry } from '../types/conversion';

export function engineBadgeClass(engine: string): string {
  const key = engine.toLowerCase().split(/[-_]/)[0];
  const known = ['edge', 'piper'];
  return known.includes(key) ? `engine-badge engine-badge--${key}` : 'engine-badge';
}

export function EngineBadges({ entry }: { entry: ChapterProgressEntry }) {
  // Prefer engineSequence (full fallback trail) over single engine field
  const seq = entry.engineSequence?.filter(Boolean);
  const engines = seq && seq.length > 0 ? seq : entry.engine ? [entry.engine] : [];
  if (engines.length === 0) return null;
  // Deduplicate consecutive identical engines
  const deduped = engines.filter((e, i) => i === 0 || e !== engines[i - 1]);
  return (
    <span className="chapter-progress__engine">
      {deduped.map((eng, i) => (
        <span key={i}>
          {i > 0 && <span className="engine-badge-arrow">→</span>}
          <span className={engineBadgeClass(eng)}>{eng}</span>
        </span>
      ))}
    </span>
  );
}

export const STATUS_ICONS: Record<ChapterProgressEntry['status'], string> = {
  completed: '✅',
  processing: '⏳',
  pending: '•',
  skipped: '⏭️',
  failed: '⚠️',
  cancelled: '⛔',
  retrying: '🔄',
};

export const STREAM_REFRESH_MS = 1500;

export function formatChapterDuration(
  value: number | undefined,
  formatLabel: (value: string) => string,
): string | null {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    return null;
  }
  const total = Math.max(0, Math.round(value));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = total % 60;
  const parts: string[] = [];
  if (hours > 0) {
    parts.push(`${hours.toString().padStart(2, '0')}h`);
  }
  if (hours > 0 || minutes > 0) {
    parts.push(`${minutes.toString().padStart(2, '0')}m`);
  }
  parts.push(`${seconds.toString().padStart(2, '0')}s`);
  return formatLabel(parts.join(' '));
}
