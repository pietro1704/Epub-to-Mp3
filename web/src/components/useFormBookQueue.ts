import { DragEvent } from 'react';
import type { FormStateScope } from './useFormState';
import type { ConversionFormProps } from './conversion_form_contract';

type FormBookQueueInput = Pick<
  FormStateScope,
  | 'fileQueue'
  | 'setDraggingId'
  | 'setDragOverInfo'
  | 'draggingId'
  | 'dragOverInfo'
  | 'setFileQueueSafe'
> &
  Pick<ConversionFormProps, 'isSubmitting'>;

export function useFormBookQueue({
  fileQueue,
  isSubmitting,
  setDraggingId,
  setDragOverInfo,
  draggingId,
  dragOverInfo,
  setFileQueueSafe,
}: FormBookQueueInput) {
  const handleDragStart = (event: DragEvent<HTMLLIElement>, entryId: string) => {
    if (fileQueue.length <= 1 || isSubmitting) {
      event.preventDefault();
      return;
    }
    setDraggingId(entryId);
    setDragOverInfo(null);
    if (event.dataTransfer) {
      event.dataTransfer.setData('text/plain', entryId);
      event.dataTransfer.effectAllowed = 'move';
    }
  };

  const handleDragOverItem = (event: DragEvent<HTMLLIElement>, entryId: string) => {
    if (!draggingId || entryId === draggingId) {
      return;
    }
    event.preventDefault();
    const rect = event.currentTarget.getBoundingClientRect();
    const offset = event.clientY - rect.top;
    const position: 'before' | 'after' = offset > rect.height / 2 ? 'after' : 'before';
    setDragOverInfo({ id: entryId, position });
  };

  const handleDropOnItem = (event: DragEvent<HTMLLIElement>, entryId: string) => {
    if (!draggingId) {
      return;
    }
    event.preventDefault();
    const info =
      dragOverInfo && dragOverInfo.id === entryId
        ? dragOverInfo
        : { id: entryId, position: 'before' as const };
    const targetIndex = fileQueue.findIndex((entry) => entry.id === entryId);
    if (targetIndex === -1) {
      return;
    }
    const insertIndex = info.position === 'after' ? targetIndex + 1 : targetIndex;
    moveEntryToIndex(draggingId, insertIndex);
    setDragOverInfo(null);
  };

  const handleDropAtEnd = (event: DragEvent<HTMLElement>) => {
    if (!draggingId) {
      return;
    }
    event.preventDefault();
    moveEntryToIndex(draggingId, fileQueue.length);
    setDragOverInfo(null);
  };

  const handleDragEnd = () => {
    setDraggingId(null);
    setDragOverInfo(null);
  };

  const formatFileSize = (bytes: number): string => {
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(1)} KB`;
    }
    if (bytes < 1024 * 1024 * 1024) {
      return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
    }
    return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GB`;
  };

  const removeFromQueue = (entryId: string) => {
    setFileQueueSafe((prev) => prev.filter((entry) => entry.id !== entryId));
  };

  const moveEntry = (entryId: string, delta: number) => {
    setFileQueueSafe((prev) => {
      const index = prev.findIndex((entry) => entry.id === entryId);
      if (index === -1) {
        return prev;
      }
      const targetIndex = index + delta;
      if (targetIndex < 0 || targetIndex >= prev.length) {
        return prev;
      }
      const next = [...prev];
      const [item] = next.splice(index, 1);
      next.splice(targetIndex, 0, item);
      return next;
    });
  };

  const moveEntryToIndex = (entryId: string, targetIndex: number) => {
    setFileQueueSafe((prev) => {
      const currentIndex = prev.findIndex((entry) => entry.id === entryId);
      if (currentIndex === -1) {
        return prev;
      }
      const constrained = Math.max(0, Math.min(prev.length, targetIndex));
      if (constrained === currentIndex || constrained === currentIndex + 1) {
        return prev;
      }
      const next = [...prev];
      const [item] = next.splice(currentIndex, 1);
      const insertIndex = constrained > currentIndex ? constrained - 1 : constrained;
      next.splice(insertIndex, 0, item);
      return next;
    });
  };

  return {
    handleDropAtEnd,
    handleDragStart,
    handleDragOverItem,
    handleDropOnItem,
    handleDragEnd,
    formatFileSize,
    moveEntry,
    removeFromQueue,
  };
}

export type FormBookQueueScope = ReturnType<typeof useFormBookQueue>;
