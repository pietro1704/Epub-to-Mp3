import { useEffect, useRef } from "react";

interface ConfirmDialogProps {
  open: boolean;
  title: string;
  message: string;
  confirmLabel: string;
  cancelLabel: string;
  onConfirm: () => void;
  onCancel: () => void;
  onClose?: () => void;
  variant?: "default" | "danger";
  showCloseButton?: boolean;
}

export default function ConfirmDialog({
  open,
  title,
  message,
  confirmLabel,
  cancelLabel,
  onConfirm,
  onCancel,
  onClose,
  variant = "default",
  showCloseButton = false,
}: ConfirmDialogProps): JSX.Element | null {
  const dialogRef = useRef<HTMLDialogElement>(null);
  const confirmBtnRef = useRef<HTMLButtonElement>(null);

  const handleClose = onClose ?? onCancel;

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;

    if (open) {
      if (!dialog.open) {
        dialog.showModal();
      }
      confirmBtnRef.current?.focus();
    } else {
      if (dialog.open) {
        dialog.close();
      }
    }
  }, [open]);

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;

    const handleEsc = (e: Event) => {
      e.preventDefault();
      handleClose();
    };

    dialog.addEventListener("cancel", handleEsc);
    return () => dialog.removeEventListener("cancel", handleEsc);
  }, [handleClose]);

  if (!open) return null;

  return (
    <dialog ref={dialogRef} className="confirm-dialog">
      <div className="confirm-dialog__content">
        <div className="confirm-dialog__header">
          <h3 className="confirm-dialog__title">{title}</h3>
          {showCloseButton && (
            <button
              type="button"
              className="confirm-dialog__close"
              onClick={handleClose}
              aria-label="Close"
            >
              ×
            </button>
          )}
        </div>
        <p className="confirm-dialog__message">{message}</p>
        <div className="confirm-dialog__actions">
          <button
            type="button"
            className="confirm-dialog__btn confirm-dialog__btn--cancel"
            onClick={onCancel}
          >
            {cancelLabel}
          </button>
          <button
            ref={confirmBtnRef}
            type="button"
            className={`confirm-dialog__btn confirm-dialog__btn--confirm ${variant === "danger" ? "confirm-dialog__btn--danger" : ""}`}
            onClick={onConfirm}
          >
            {confirmLabel}
          </button>
        </div>
      </div>
    </dialog>
  );
}
