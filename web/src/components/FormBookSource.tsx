import type { ConversionFormScope } from './useConversionFormController';

type FormBookSourceProps = Pick<
  ConversionFormScope,
  | 'addFilesToQueue'
  | 'folderInputRef'
  | 't'
  | 'isSubmitting'
  | 'handleUseSample'
  | 'fileError'
  | 'fileQueue'
  | 'currentJob'
  | 'draggingId'
  | 'setDragOverInfo'
  | 'END_DROP_ID'
  | 'handleDropAtEnd'
  | 'dragOverInfo'
  | 'handleDragStart'
  | 'handleDragOverItem'
  | 'handleDropOnItem'
  | 'handleDragEnd'
  | 'formatFileSize'
  | 'moveEntry'
  | 'removeFromQueue'
>;

export function FormBookSource({
  addFilesToQueue,
  folderInputRef,
  t,
  isSubmitting,
  handleUseSample,
  fileError,
  fileQueue,
  currentJob,
  draggingId,
  setDragOverInfo,
  END_DROP_ID,
  handleDropAtEnd,
  dragOverInfo,
  handleDragStart,
  handleDragOverItem,
  handleDropOnItem,
  handleDragEnd,
  formatFileSize,
  moveEntry,
  removeFromQueue,
}: FormBookSourceProps): JSX.Element {
  return (
    <>
      <fieldset className="form-field">
        <label htmlFor="file">{t.form.fileLabel}</label>
        <div className="file-input-row">
          <input
            id="file"
            name="file"
            type="file"
            accept="application/epub+zip,application/pdf"
            multiple
            disabled={isSubmitting}
            onChange={(event) => {
              const files = event.target.files;
              if (files && files.length > 0) {
                addFilesToQueue(files);
                event.target.value = '';
              }
            }}
            className="file-input-row__input"
          />
          <button
            type="button"
            onClick={handleUseSample}
            disabled={isSubmitting}
            className="button-secondary file-input-row__sample"
          >
            {t.form.useSampleButton}
          </button>
          <button
            type="button"
            onClick={() => folderInputRef.current?.click()}
            disabled={isSubmitting}
            className="button-secondary file-input-row__sample"
            style={{ marginLeft: '0.5rem' }}
          >
            {t.form.addFolderButton}
          </button>
        </div>
        {fileError && (
          <p role="alert" className="form-error">
            {fileError}
          </p>
        )}
        <div className="file-queue">
          <div className="file-queue__header">
            <span className="file-queue__title">{t.form.fileQueueLabel}</span>
            {fileQueue.length > 0 && (
              <span className="file-queue__count">{t.form.fileQueueCount(fileQueue.length)}</span>
            )}
          </div>
          {fileQueue.length === 0 ? (
            <p className="form-hint">
              {currentJob && currentJob.bookTitle
                ? t.form.fileQueueWithCurrent(currentJob.bookTitle)
                : t.form.fileQueueEmpty}
            </p>
          ) : (
            <>
              <ul
                className="file-queue__list"
                onDragOver={(event) => {
                  if (!draggingId || event.target !== event.currentTarget) return;
                  event.preventDefault();
                  setDragOverInfo({ id: END_DROP_ID, position: 'after' });
                }}
                onDrop={(event) => {
                  if (event.target === event.currentTarget) {
                    handleDropAtEnd(event);
                  }
                }}
              >
                {fileQueue.map((entry, index) => {
                  const canMoveUp = index > 0;
                  const canMoveDown = index < fileQueue.length - 1;
                  const isDragging = entry.id === draggingId;
                  const dropBefore =
                    dragOverInfo?.id === entry.id && dragOverInfo.position === 'before';
                  const dropAfter =
                    dragOverInfo?.id === entry.id && dragOverInfo.position === 'after';
                  const itemClasses = [
                    'file-queue__item',
                    isDragging ? 'file-queue__item--dragging' : '',
                    dropBefore ? 'file-queue__item--drop-before' : '',
                    dropAfter ? 'file-queue__item--drop-after' : '',
                  ]
                    .filter(Boolean)
                    .join(' ');
                  return (
                    <li
                      key={entry.id}
                      className={itemClasses}
                      draggable={fileQueue.length > 1 && !isSubmitting}
                      onDragStart={(event) => handleDragStart(event, entry.id)}
                      onDragOver={(event) => handleDragOverItem(event, entry.id)}
                      onDrop={(event) => handleDropOnItem(event, entry.id)}
                      onDragEnd={handleDragEnd}
                    >
                      <div className="file-queue__meta">
                        <span className="file-queue__name" title={entry.name}>
                          {index + 1}. {entry.name}
                        </span>
                        {entry.bookTitle && (
                          <span className="file-queue__book-info">
                            <strong>{entry.bookTitle}</strong>
                            {entry.bookAuthor && <span> — {entry.bookAuthor}</span>}
                          </span>
                        )}
                        <span className="file-queue__details">
                          {formatFileSize(entry.size)} •{' '}
                          {entry.status === 'ready' && <span>✅ {t.form.autoUploadReady}</span>}
                          {entry.status === 'uploading' && <span>📤 {t.form.uploadingFile}</span>}
                          {entry.status === 'error' && <span>⚠️ {entry.error}</span>}
                        </span>
                      </div>
                      <div className="file-queue__actions">
                        <button
                          type="button"
                          className="file-queue__swap"
                          onClick={() => moveEntry(entry.id, -1)}
                          disabled={!canMoveUp || isSubmitting}
                          aria-label={t.form.fileQueueMoveUp}
                          title={t.form.fileQueueMoveUp}
                        >
                          ↑
                        </button>
                        <button
                          type="button"
                          className="file-queue__swap"
                          onClick={() => moveEntry(entry.id, 1)}
                          disabled={!canMoveDown || isSubmitting}
                          aria-label={t.form.fileQueueMoveDown}
                          title={t.form.fileQueueMoveDown}
                        >
                          ↓
                        </button>
                        <button
                          type="button"
                          className="file-queue__remove"
                          onClick={() => removeFromQueue(entry.id)}
                          disabled={isSubmitting}
                        >
                          {t.form.fileQueueRemove}
                        </button>
                      </div>
                    </li>
                  );
                })}
              </ul>
              {fileQueue.length > 1 && (
                <>
                  <div
                    className={`file-queue__dropzone ${dragOverInfo?.id === END_DROP_ID ? 'file-queue__dropzone--active' : ''}`}
                    onDragOver={(event) => {
                      if (!draggingId) return;
                      event.preventDefault();
                      setDragOverInfo({ id: END_DROP_ID, position: 'after' });
                    }}
                    onDrop={handleDropAtEnd}
                    onDragLeave={() => {
                      if (dragOverInfo?.id === END_DROP_ID) {
                        setDragOverInfo(null);
                      }
                    }}
                  >
                    {t.form.fileQueueReorderHint}
                  </div>
                </>
              )}
            </>
          )}
        </div>
        <p className="form-hint">{t.form.autoUploadHint}</p>
        <p className="form-hint">{t.form.fileHint}</p>
      </fieldset>
    </>
  );
}
