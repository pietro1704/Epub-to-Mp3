import { ChangeEvent, useState } from 'react';
import { MAX_UPLOAD_BYTES, MAX_UPLOAD_MB } from '../config';
import { useTranslations } from '../i18n/I18nProvider';
import type { ConversionFormValues, ConversionTemplate, ConversionState } from '../types/conversion';

type Phase = ConversionState['phase'];

interface QuickQueueAdderProps {
  template: ConversionTemplate;
  enqueue: (jobs: ConversionFormValues[]) => Promise<void>;
  phase: Phase;
}

export default function QuickQueueAdder({ template, enqueue, phase }: QuickQueueAdderProps): JSX.Element {
  const t = useTranslations();
  const [statusMessage, setStatusMessage] = useState<string | null>(null);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [isAdding, setIsAdding] = useState(false);

  const handleFileChange = async (event: ChangeEvent<HTMLInputElement>) => {
    const files = event.target.files;
    event.target.value = '';
    if (!files || files.length === 0) {
      return;
    }
    const jobs: ConversionFormValues[] = [];
    for (const file of Array.from(files)) {
      if (file.size > MAX_UPLOAD_BYTES) {
        setErrorMessage(t.form.errorFileTooLarge(Math.round(MAX_UPLOAD_MB)));
        setStatusMessage(null);
        return;
      }
      jobs.push({
        ...template,
        file,
        fileName: file.name,
        uploadId: undefined,
      });
    }
    if (jobs.length === 0) {
      return;
    }
    setIsAdding(true);
    setErrorMessage(null);
    try {
      await enqueue(jobs);
      setStatusMessage(t.queue.success(jobs.length));
    } catch (error) {
      const message = error instanceof Error && error.message
        ? error.message
        : t.queue.errorFallback;
      setErrorMessage(message);
      setStatusMessage(null);
    } finally {
      setIsAdding(false);
    }
  };

  const phaseLabel = phase === 'success'
    ? t.queue.phaseSuccess
    : t.queue.phaseActive;

  return (
    <div className="queue-adder">
      <div className="queue-adder__header">
        <div>
          <h3>{t.queue.title}</h3>
          <p>{t.queue.subtitle}</p>
        </div>
        <span className="queue-adder__phase">{phaseLabel}</span>
      </div>
      <label className="queue-adder__input">
        <span>{t.queue.inputLabel}</span>
        <input
          type="file"
          multiple
          accept="application/epub+zip,application/pdf"
          disabled={isAdding}
          onChange={handleFileChange}
        />
      </label>
      <p className="queue-adder__hint">{t.queue.hint}</p>
      {statusMessage && <p className="queue-adder__status">{statusMessage}</p>}
      {errorMessage && <p className="queue-adder__error">{errorMessage}</p>}
    </div>
  );
}
