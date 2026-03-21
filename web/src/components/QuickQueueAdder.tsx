import { ChangeEvent, useEffect, useRef, useState } from "react";
import { MAX_UPLOAD_BYTES, MAX_UPLOAD_MB } from "../config";
import { useTranslations } from "../i18n/I18nProvider";
import type {
  ConversionFormValues,
  ConversionTemplate,
  ConversionState,
} from "../types/conversion";
import type { UploadResponse } from "../services/ConversionService";

type Phase = ConversionState["phase"];

interface QuickQueueAdderProps {
  template: ConversionTemplate;
  enqueue: (jobs: ConversionFormValues[]) => Promise<void>;
  phase: Phase;
  uploadFile: (file: File) => Promise<UploadResponse>;
  onJobsAdded?: (count: number) => void;
}

const SUPPORTED_BOOK_EXTENSIONS = new Set([".epub", ".pdf"]);

export default function QuickQueueAdder({
  template,
  enqueue,
  phase,
  uploadFile,
  onJobsAdded,
}: QuickQueueAdderProps): JSX.Element {
  const t = useTranslations();
  const [statusMessage, setStatusMessage] = useState<string | null>(null);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [isAdding, setIsAdding] = useState(false);
  const folderInputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    const input = folderInputRef.current;
    if (!input) {
      return;
    }
    input.setAttribute("webkitdirectory", "");
    input.setAttribute("directory", "");
    input.setAttribute("mozdirectory", "");
  }, []);

  const handleFileChange = async (event: ChangeEvent<HTMLInputElement>) => {
    const files = event.target.files;
    event.target.value = "";
    if (!files || files.length === 0) {
      return;
    }
    const jobs: ConversionFormValues[] = [];
    setIsAdding(true);
    setErrorMessage(null);
    try {
      for (const file of Array.from(files)) {
        if (file.size > MAX_UPLOAD_BYTES) {
          setErrorMessage(t.form.errorFileTooLarge(Math.round(MAX_UPLOAD_MB)));
          setStatusMessage(null);
          setIsAdding(false);
          return;
        }
        const ext = file.name?.split(".").pop()?.toLowerCase() ?? "";
        if (ext && !SUPPORTED_BOOK_EXTENSIONS.has(`.${ext}`)) {
          continue;
        }
        const response = await uploadFile(file);
        jobs.push({
          ...template,
          file: null,
          fileName: response.fileName || file.name,
          uploadId: response.uploadId,
          bookTitle: response.bookTitle,
          bookAuthor: response.bookAuthor,
          coverUrl: response.coverUrl,
        });
      }
      if (jobs.length === 0) {
        setIsAdding(false);
        return;
      }
      await enqueue(jobs);
      onJobsAdded?.(jobs.length);
      setStatusMessage(t.queue.success(jobs.length));
    } catch (error) {
      const message =
        error instanceof Error && error.message
          ? error.message
          : t.queue.errorFallback;
      setErrorMessage(message);
      setStatusMessage(null);
    } finally {
      setIsAdding(false);
    }
  };

  const phaseLabel =
    phase === "success" ? t.queue.phaseSuccess : t.queue.phaseActive;

  return (
    <div className="queue-adder">
      <input
        ref={folderInputRef}
        type="file"
        multiple
        style={{ display: "none" }}
        onChange={handleFileChange}
      />
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
      <button
        type="button"
        className="queue-adder__folder-button"
        onClick={() => folderInputRef.current?.click()}
        disabled={isAdding}
      >
        {t.queue.addFolderButton}
      </button>
      <p className="queue-adder__hint">{t.queue.hint}</p>
      {statusMessage && <p className="queue-adder__status">{statusMessage}</p>}
      {errorMessage && <p className="queue-adder__error">{errorMessage}</p>}
    </div>
  );
}
