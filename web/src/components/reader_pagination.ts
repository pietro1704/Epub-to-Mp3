import { ReaderPrefs } from './reader_preferences';
import { stripHtml, sanitizeReaderTree, escapeHtml } from './reader_markup';
import { applyReaderHighlight } from './reader_highlighting';

export interface ReaderPage {
  html: string;
  hasAudio: boolean;
}

export function buildReaderPages(
  sourceHtml: string | undefined,
  fallbackText: string,
  options: { audioText: string; searchText: string },
  prefs: ReaderPrefs,
): ReaderPage[] {
  if (typeof window === 'undefined') {
    return [{ html: buildReaderHtmlFallback(fallbackText), hasAudio: false }];
  }

  const parser = new DOMParser();
  const baseMarkup = sourceHtml?.trim() || buildReaderHtmlFallback(fallbackText);
  const doc = parser.parseFromString(baseMarkup, 'text/html');
  const root = doc.body;

  sanitizeReaderTree(root, doc);
  applyReaderHighlight(root, doc, options.audioText.trim(), 'audio');
  applyReaderHighlight(root, doc, options.searchText.trim(), 'search');
  const pages = paginateReaderRoot(root, prefs);
  return pages.length > 0
    ? pages
    : [{ html: buildReaderHtmlFallback(fallbackText), hasAudio: false }];
}

export function buildReaderHtmlFallback(text: string): string {
  const source = (text || '').trim();
  if (!source) {
    return '<p></p>';
  }
  return source
    .split(/\n{2,}/)
    .map((paragraph) => `<p>${escapeHtml(paragraph).replace(/\n/g, '<br />')}</p>`)
    .join('');
}

export function paginateReaderRoot(root: HTMLElement, prefs: ReaderPrefs): ReaderPage[] {
  const pageSource = resolvePaginationSource(root);
  const blocks = Array.from(pageSource.childNodes)
    .map((node) => {
      if (node.nodeType === Node.TEXT_NODE) {
        const text = node.textContent?.trim() || '';
        return text ? `<p>${escapeHtml(text)}</p>` : '';
      }
      return node instanceof Element ? node.outerHTML : '';
    })
    .filter(Boolean);

  if (blocks.length === 0) {
    return [];
  }

  const charBudget = estimateReaderPageChars(prefs);
  const pages: ReaderPage[] = [];
  let currentBlocks: string[] = [];
  let currentChars = 0;
  let currentHasAudio = false;

  blocks.forEach((block) => {
    const blockTextLength = stripHtml(block).length;
    const nextChars = currentChars + blockTextLength;
    const blockHasAudio =
      block.includes("data-reader-audio='true'") || block.includes('data-reader-audio="true"');
    if (currentBlocks.length > 0 && nextChars > charBudget) {
      pages.push({
        html: currentBlocks.join(''),
        hasAudio: currentHasAudio,
      });
      currentBlocks = [];
      currentChars = 0;
      currentHasAudio = false;
    }
    currentBlocks.push(block);
    currentChars += blockTextLength;
    currentHasAudio = currentHasAudio || blockHasAudio;
  });

  if (currentBlocks.length > 0) {
    pages.push({
      html: currentBlocks.join(''),
      hasAudio: currentHasAudio,
    });
  }

  return pages;
}

export function resolvePaginationSource(root: HTMLElement): HTMLElement {
  if (root.children.length !== 1) {
    return root;
  }
  const child = root.firstElementChild;
  if (
    child instanceof HTMLElement &&
    ['section', 'article', 'div', 'main'].includes(child.tagName.toLowerCase()) &&
    child.children.length > 1
  ) {
    return child;
  }
  return root;
}

export function estimateReaderPageChars(prefs: ReaderPrefs): number {
  const widthFactor = prefs.widthRem / 48;
  const fontFactor = 1.05 / prefs.fontScale;
  const lineFactor = 1.75 / prefs.lineHeight;
  return Math.max(900, Math.min(4200, Math.round(2200 * widthFactor * fontFactor * lineFactor)));
}
