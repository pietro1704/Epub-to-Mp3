import { useEffect, useMemo, useState } from "react";
import { useTranslations } from "../i18n/I18nProvider";

interface QueuedItem {
  fileName?: string;
  bookTitle?: string;
  engine?: string;
  voice?: string;
}

interface QueueDisplayProps {
  currentJob?: {
    fileName?: string;
    bookTitle?: string;
  };
  queue: QueuedItem[];
  queuePaused?: boolean;
  onResumeQueue?: () => void;
  onClearQueue?: () => void;
  onReorderQueue?: (fromIndex: number, toIndex: number) => void;
  totalJobs?: number;
  overallPercent?: number | null;
}

export default function QueueDisplay({
  currentJob,
  queue,
  queuePaused = false,
  onResumeQueue,
  onClearQueue,
  onReorderQueue,
  totalJobs,
  overallPercent,
}: QueueDisplayProps): JSX.Element | null {
  const t = useTranslations();
  const fallbackTitle = t.status.bookFallbackTitle;
  const [expanded, setExpanded] = useState(false);
  const [dragIndex, setDragIndex] = useState<number | null>(null);
  const showAll = expanded || queue.length <= 3;
  const visibleQueue = useMemo(
    () => (showAll ? queue : queue.slice(0, 3)),
    [queue, showAll],
  );
  useEffect(() => {
    if (queue.length <= 3 && expanded) {
      setExpanded(false);
    }
  }, [queue.length, expanded]);

  if (!currentJob && queue.length === 0) {
    return null;
  }

  return (
    <div className="queue-display">
      {typeof totalJobs === "number" && totalJobs > 0 && (
        <div className="queue-display__progress">
          <div className="queue-display__progress-bar">
            <div
              className="queue-display__progress-fill"
              style={{
                width: `${Math.min(100, Math.max(0, overallPercent ?? 0))}%`,
              }}
            />
          </div>
          <div className="queue-display__progress-meta">
            <span>{`${Math.max(0, totalJobs - (queue.length + (currentJob ? 1 : 0)))} / ${totalJobs}`}</span>
            <strong>{`${Math.round(Math.min(100, Math.max(0, overallPercent ?? 0)))}%`}</strong>
          </div>
        </div>
      )}
      {currentJob && (
        <div className="queue-display__current">
          <span className="queue-display__label">
            {t.queue.displayCurrentLabel}:
          </span>
          <strong className="queue-display__value">
            {currentJob.bookTitle || currentJob.fileName || fallbackTitle}
          </strong>
        </div>
      )}

      {queue.length > 0 && (
        <div className="queue-display__pending">
          <div className="queue-display__header">
            <span className="queue-display__label">
              {t.queue.displayQueueLabel(queue.length)}
            </span>
            {queuePaused && (
              <span className="queue-display__paused-badge">
                {t.queue.displayPausedBadge}
              </span>
            )}
          </div>

          <ul className="queue-display__list">
            {visibleQueue.map((item, index) => {
              const globalIndex = index;
              const isFirst = globalIndex === 0;
              const isLast = queue.length - 1 === globalIndex;
              return (
                <li
                  key={`${item.fileName}-${index}`}
                  className="queue-display__item"
                  draggable={Boolean(onReorderQueue)}
                  onDragStart={(event) => {
                    if (!onReorderQueue) return;
                    setDragIndex(globalIndex);
                    event.dataTransfer?.setData(
                      "text/plain",
                      String(globalIndex),
                    );
                  }}
                  onDragOver={(event) => {
                    if (!onReorderQueue) return;
                    event.preventDefault();
                  }}
                  onDrop={(event) => {
                    if (!onReorderQueue) return;
                    event.preventDefault();
                    if (dragIndex !== null && dragIndex !== globalIndex) {
                      onReorderQueue(dragIndex, globalIndex);
                    }
                    setDragIndex(null);
                  }}
                  onDragEnd={() => setDragIndex(null)}
                >
                  <span className="queue-display__position">{index + 1}.</span>
                  <span className="queue-display__name">
                    {item.bookTitle || item.fileName || fallbackTitle}
                  </span>
                  {item.engine && (
                    <span className="queue-display__engine">{item.engine}</span>
                  )}
                  {showAll && onReorderQueue && queue.length > 1 && (
                    <span className="queue-display__item-actions">
                      <button
                        type="button"
                        className="queue-display__move-button"
                        onClick={() =>
                          onReorderQueue(globalIndex, globalIndex - 1)
                        }
                        disabled={isFirst}
                        aria-label={t.queue.displayMoveUp}
                      >
                        ↑
                      </button>
                      <button
                        type="button"
                        className="queue-display__move-button"
                        onClick={() =>
                          onReorderQueue(globalIndex, globalIndex + 1)
                        }
                        disabled={isLast}
                        aria-label={t.queue.displayMoveDown}
                      >
                        ↓
                      </button>
                    </span>
                  )}
                </li>
              );
            })}
            {!showAll && queue.length > 3 && (
              <li className="queue-display__more">
                <button type="button" onClick={() => setExpanded(true)}>
                  {t.queue.displayMoreLabel(queue.length - 3)}
                </button>
              </li>
            )}
          </ul>

          <div className="queue-display__actions">
            {showAll && queue.length > 3 && (
              <button
                type="button"
                className="queue-display__action-button queue-display__action-button--secondary"
                onClick={() => setExpanded(false)}
              >
                {t.queue.displayShowLess}
              </button>
            )}
            {queuePaused && onResumeQueue && (
              <button
                type="button"
                className="queue-display__action-button queue-display__action-button--primary"
                onClick={onResumeQueue}
              >
                {t.queue.displayResumeButton}
              </button>
            )}
            {onClearQueue && (
              <button
                type="button"
                className="queue-display__action-button queue-display__action-button--secondary"
                onClick={onClearQueue}
              >
                {t.queue.displayClearButton}
              </button>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
