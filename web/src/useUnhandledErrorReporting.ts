import { useEffect } from 'react';
import { reportUiIssue } from './services/uiIssueMonitor';

export function useUnhandledErrorReporting() {
  useEffect(() => {
    if (typeof window === 'undefined') {
      return;
    }

    const handleError = (event: ErrorEvent) => {
      reportUiIssue('app', 'Unhandled UI error', {
        severity: 'error',
        details: event.message || 'Unknown browser error',
      });
    };

    const handleRejection = (event: PromiseRejectionEvent) => {
      const reason =
        typeof event.reason === 'string'
          ? event.reason
          : event.reason instanceof Error
            ? event.reason.message
            : 'Unknown rejection';
      reportUiIssue('app', 'Unhandled async UI error', {
        severity: 'error',
        details: reason,
      });
    };

    window.addEventListener('error', handleError);
    window.addEventListener('unhandledrejection', handleRejection);
    return () => {
      window.removeEventListener('error', handleError);
      window.removeEventListener('unhandledrejection', handleRejection);
    };
  }, []);
}
