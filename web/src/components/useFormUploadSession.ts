import { useEffect } from 'react';
import { MAX_UPLOAD_BYTES } from '../config';

import { QueuedFileEntry, SUPPORTED_BOOK_EXTENSIONS } from './conversion_form_choices';

import type { FormStateScope } from './useFormState';
import type { FormNarrationPolicyScope } from './useFormNarrationPolicy';
import type { ConversionFormProps } from './conversion_form_contract';

type FormUploadSessionInput = Pick<
  FormStateScope,
  | 'folderInputRef'
  | 'fileQueueRef'
  | 'fileQueue'
  | 'uploadPromisesRef'
  | 'uploadAttemptRef'
  | 'setPendingUploads'
  | 'setFileQueueSafe'
  | 'setFileError'
  | 't'
  | 'setShowMissingFileError'
> &
  Pick<FormNarrationPolicyScope, 'maxUploadMbDisplay'> &
  Pick<ConversionFormProps, 'onUploadStateChange' | 'onUploadFile'>;

export function useFormUploadSession({
  folderInputRef,
  fileQueueRef,
  fileQueue,
  onUploadStateChange,
  uploadPromisesRef,
  uploadAttemptRef,
  setPendingUploads,
  setFileQueueSafe,
  onUploadFile,
  setFileError,
  t,
  maxUploadMbDisplay,
  setShowMissingFileError,
}: FormUploadSessionInput) {
  useEffect(() => {
    const input = folderInputRef.current;
    if (!input) {
      return;
    }
    input.setAttribute('webkitdirectory', '');
    input.setAttribute('directory', '');
    input.setAttribute('mozdirectory', '');
  }, []);

  useEffect(() => {
    fileQueueRef.current = fileQueue;
    const pending = fileQueue.filter((entry) => entry.status === 'uploading').length;
    onUploadStateChange?.(pending);
  }, [fileQueue, onUploadStateChange]);

  const startUploadForEntry = (entryId: string, file: File) => {
    // Skip if an upload already exists or is in progress for this entry
    if (uploadPromisesRef.current[entryId]) {
      return;
    }
    const existing = fileQueueRef.current.find((entry) => entry.id === entryId);
    if (existing?.uploadId && existing.status === 'ready') {
      return;
    }

    const attemptId = uploadAttemptRef.current + 1;
    uploadAttemptRef.current = attemptId;
    setPendingUploads((count) => count + 1);
    setFileQueueSafe((prev) =>
      prev.map((entry) =>
        entry.id === entryId
          ? { ...entry, status: 'uploading', error: undefined, attemptId }
          : entry,
      ),
    );
    const uploadPromise = (async () => {
      try {
        const response = await onUploadFile(file);
        setFileQueueSafe((prev) =>
          prev.map((entry) => {
            if (entry.id !== entryId || entry.attemptId !== attemptId) {
              return entry;
            }
            return {
              ...entry,
              status: 'ready',
              uploadId: response.uploadId,
              name: response.fileName || entry.name,
              bookTitle: response.bookTitle,
              bookAuthor: response.bookAuthor,
              coverUrl: response.coverUrl,
              attemptId: undefined,
            };
          }),
        );
      } catch (error) {
        const message = error instanceof Error ? error.message : 'File upload failed';
        const unsupported =
          typeof message === 'string' &&
          (message.toLowerCase().includes('not supported') ||
            message.toLowerCase().includes('unsupported'));
        if (unsupported) {
          setFileQueueSafe((prev) =>
            prev.map((entry) => {
              if (entry.id !== entryId || entry.attemptId !== attemptId) {
                return entry;
              }
              return {
                ...entry,
                status: 'ready',
                error: undefined,
                attemptId: undefined,
              };
            }),
          );
          return;
        }
        setFileQueueSafe((prev) =>
          prev.map((entry) => {
            if (entry.id !== entryId || entry.attemptId !== attemptId) {
              return entry;
            }
            return {
              ...entry,
              status: 'error',
              error: message,
              attemptId: undefined,
            };
          }),
        );
      }
    })();
    uploadPromisesRef.current[entryId] = uploadPromise;
    uploadPromise.finally(() => {
      delete uploadPromisesRef.current[entryId];
      setPendingUploads((count) => Math.max(0, count - 1));
      onUploadStateChange?.(
        fileQueueRef.current.filter((entry) => entry.status === 'uploading').length,
      );
    });
  };

  const addFilesToQueue = (files: FileList | File[]) => {
    const additions: QueuedFileEntry[] = [];
    Array.from(files).forEach((file) => {
      if (!file) return;
      if (file.size > MAX_UPLOAD_BYTES) {
        setFileError(`${t.form.errorFileTooLarge(maxUploadMbDisplay)} (${file.name})`);
        return;
      }
      const ext = file.name?.split('.').pop()?.toLowerCase() ?? '';
      const normalizedExt = ext ? `.${ext}` : '';
      if (!SUPPORTED_BOOK_EXTENSIONS.has(normalizedExt)) {
        return;
      }
      const id =
        typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function'
          ? crypto.randomUUID()
          : `queued-${Date.now()}-${Math.random().toString(16).slice(2)}`;
      additions.push({
        id,
        file,
        name: file.name,
        size: file.size,
        status: 'uploading',
      });
    });
    if (additions.length === 0) {
      return;
    }
    setFileError(null);
    setShowMissingFileError(false);
    setFileQueueSafe((prev) => [...prev, ...additions]);
    additions.forEach((entry) => startUploadForEntry(entry.id, entry.file));
  };

  return { addFilesToQueue };
}

export type FormUploadSessionScope = ReturnType<typeof useFormUploadSession>;
