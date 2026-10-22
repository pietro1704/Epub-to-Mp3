export type ReaderTheme = 'paper' | 'mist' | 'ink';

export type ReaderFontFamily = 'serif' | 'sans';

export interface ReaderPrefs {
  fontScale: number;
  lineHeight: number;
  widthRem: number;
  theme: ReaderTheme;
  followAudio: boolean;
  fontFamily: ReaderFontFamily;
}

export const PREFS_KEY = 'epub-to-mp3:reader-prefs';

export const DEFAULT_PREFS: ReaderPrefs = {
  fontScale: 1.05,
  lineHeight: 1.75,
  widthRem: 48,
  theme: 'paper',
  followAudio: true,
  fontFamily: 'serif',
};

export const READER_CONTENT_BASE_CSS = `
  .reader-root {
    color: var(--reader-text);
    font-family: var(--reader-font-family, "Iowan Old Style", "Palatino Linotype", "Book Antiqua", "Georgia", serif);
    font-size: calc(1rem * var(--reader-font-scale, 1.05));
    line-height: var(--reader-line-height, 1.75);
    text-rendering: optimizeLegibility;
    font-kerning: normal;
    word-break: normal;
  }
  .reader-root p,
  .reader-root blockquote,
  .reader-root ol,
  .reader-root ul,
  .reader-root pre,
  .reader-root figure {
    margin: 0 0 1.1rem;
    text-wrap: pretty;
  }
  .reader-root h1,
  .reader-root h2,
  .reader-root h3,
  .reader-root h4,
  .reader-root h5,
  .reader-root h6 {
    margin: 1.65em 0 0.75em;
    line-height: 1.18;
    font-weight: 600;
    letter-spacing: -0.01em;
  }
  .reader-root p {
    text-indent: 1.4em;
  }
  .reader-root p:first-child,
  .reader-root h1 + p,
  .reader-root h2 + p,
  .reader-root h3 + p,
  .reader-root hr + p,
  .reader-root blockquote + p,
  .reader-root figure + p {
    text-indent: 0;
  }
  .reader-root blockquote {
    margin-left: 0;
    padding: 0.9rem 1rem;
    border-left: 3px solid color-mix(in srgb, var(--reader-accent) 32%, transparent);
    background: color-mix(in srgb, var(--reader-panel) 86%, white);
    border-radius: 0 1rem 1rem 0;
    color: var(--reader-muted);
  }
  .reader-root ol,
  .reader-root ul {
    padding-left: 1.6rem;
  }
  .reader-root li + li {
    margin-top: 0.35rem;
  }
  .reader-root a {
    color: inherit;
    text-decoration-color: color-mix(in srgb, var(--reader-accent) 45%, transparent);
  }
  .reader-root hr {
    border: none;
    border-top: 1px solid var(--reader-border);
    margin: 1.75rem auto;
    width: min(12rem, 32%);
  }
  .reader-root code,
  .reader-root pre {
    font-family: "SFMono-Regular", "Menlo", "Consolas", monospace;
  }
  .reader-root pre {
    overflow: auto;
    padding: 0.9rem 1rem;
    border-radius: 1rem;
    background: color-mix(in srgb, var(--reader-sidebar) 70%, transparent);
  }
  .ebook-reader__media-note {
    margin: 0 0 1.1rem;
    padding: 0.8rem 1rem;
    border-radius: 1rem;
    background: color-mix(in srgb, var(--reader-sidebar) 68%, transparent);
    color: var(--reader-muted);
    font-size: 0.94em;
    text-align: center;
  }
  .ebook-reader__inline-highlight {
    border-radius: 0.32rem;
    transition: background 0.18s ease;
    color: inherit;
  }
  .ebook-reader__inline-highlight.is-search {
    background: var(--reader-search);
  }
  .ebook-reader__inline-highlight.is-audio {
    background: var(--reader-audio);
    box-shadow: 0 0 0 1px color-mix(in srgb, var(--reader-accent) 24%, transparent);
  }
`;
