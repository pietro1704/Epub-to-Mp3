import type { Translations } from './translation_contract';

export const en_application: Pick<Translations, 'locale' | 'topBar' | 'hero' | 'tabs' | 'flow'> = {
  locale: 'en',
  topBar: {
    ariaLabel: 'Theme and language preferences',
    themeLabel: 'Theme',
    themeLight: 'Light',
    themeDark: 'Dark',
    themeAuto: 'Auto',
    localeLabel: 'Language',
    localeEnglish: 'English',
    localePortuguese: 'Portuguese',
    localeAuto: 'Auto',
  },
  hero: {
    badge: 'Audio book',
    title: 'Turn your EPUB or PDF into MP3 in just a few clicks',
    subtitle:
      'Open your book and convert locally with Piper. Installed system voices are listening-only; MP3 export requires Piper.',
    highlights: [
      {
        title: 'Local Piper',
        description: 'Your primary voice is preserved. Install the model when you choose to enable offline conversion.',
      },
      {
        title: 'True multilingual',
        description:
          'Detects language changes per chapter and switches voices with zero configuration.',
      },
      {
        title: 'Resume conversions',
        description: 'Smart caching resumes interrupted jobs and skips chapters already rendered.',
      },
    ],
  },
  tabs: {
    setup: {
      label: '1. Prepare conversion',
      description: 'Upload the book and choose voice, footnotes, and chapters.',
      panelTitle: 'Upload your book',
      panelDescription: 'Send the file and define how the audio should sound.',
      savedBatchTitle: (count: number) =>
        `📋 Saved queue with ${count} book${count !== 1 ? 's' : ''} pending`,
      savedBatchResume: 'Resume queue',
      savedBatchDismiss: 'Dismiss',
      savedBatchNeedsReupload: (count: number) =>
        `⚠️ ${count} book${count !== 1 ? 's need' : ' needs'} to be re-uploaded (file cannot be saved)`,
    },
    progress: {
      label: '2. Track progress',
      description: 'Follow the local book conversion on this device.',
      panelTitle: 'Conversion status',
      panelDescription: 'The latest messages show up here.',
      activeBadge: 'Running',
      backButton: '← Back',
      viewDownloads: 'View Downloads →',
    },
    downloads: {
      label: '3. Listen & download',
      description: 'Finished chapters become available for instant download.',
      panelTitle: 'Your MP3 files',
      panelDescription: 'Download the chapters or start another conversion.',
      footer: '',
      backButton: '← Back',
      followConversion: 'Follow conversion →',
    },
  },
  flow: {
    startUpload: 'Sending file to the server…',
    startReuse: 'Preparing conversion using the uploaded file…',
    jobCreated: (jobId: string) => `Request ${jobId} received. Waiting for narration…`,
    resuming: '🔄 Resuming interrupted conversion…',
    loadingCache: '📦 Loading cached progress for this conversion...',
    completion: (count: number) => `Finished conversion with ${count} audio file(s).`,
    failure: (message: string) => `Request failed: ${message}`,
    error: (message: string) => `Error: ${message}`,
    defaultFailure: 'Conversion failed',
    defaultError: 'Unexpected error',
    cancelRequested: '🛑 Cancel request received. Finishing current step…',
    cancelled: 'Request cancelled by the user.',
    skipped: 'Current book skipped, continuing with queue.',
    cancelFailed: (message: string) => `Unable to cancel: ${message || 'please try again'}`,
    skipConfirm: 'Do you want to skip this book and continue with the next one in the queue?',
    backendOffline: 'Conversion server unavailable',
    backendOfflineDetails:
      'Unable to reach the Rust conversion runtime. Check that the local runtime is available and reload the page.',
    backendConnecting: 'Connecting to the conversion server…',
    backendOfflineBanner:
      'The Rust conversion runtime is not responding. Check the local runtime and reload the page.',
    cachedRestoredSuccess:
      'Restored from local cache — downloads may be unavailable if the server was restarted.',
    cancelConfirm:
      'Cancelling now stops the current conversion and removes generated files. Continue?',
    batchPosition: (index: number, total: number) => `📚 Book ${index}/${total}`,
    batchCancelled: (remaining: number) =>
      remaining === 1
        ? 'Batch stopped. 1 book is still pending.'
        : `Batch stopped. ${remaining} books are still pending.`,
    notificationErrorTitle: 'Conversion failed',
    notificationErrorBody: 'Check the log for more details.',
    notificationCancelTitle: 'Conversion cancelled',
    notificationCancelBody:
      'Conversion cancelled and removed. You can start a new conversion whenever you want.',
  },
};
