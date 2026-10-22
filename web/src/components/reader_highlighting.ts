export function countMatches(text: string, query: string): number {
  if (!text || !query) {
    return 0;
  }
  const escaped = escapeRegExp(query);
  const regex = new RegExp(escaped, 'gi');
  return Array.from(text.matchAll(regex)).length;
}

export function applyReaderHighlight(
  root: HTMLElement,
  doc: Document,
  needle: string,
  kind: 'audio' | 'search',
): void {
  if (!needle) {
    return;
  }
  const matcher = kind === 'search' ? new RegExp(escapeRegExp(needle), 'gi') : null;
  const walker = doc.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  const textNodes: Text[] = [];

  let current = walker.nextNode();
  while (current) {
    const parent = current.parentElement;
    if (
      current.nodeType === Node.TEXT_NODE &&
      parent &&
      !parent.closest('.ebook-reader__inline-highlight')
    ) {
      textNodes.push(current as Text);
    }
    current = walker.nextNode();
  }

  let audioAssigned = false;

  textNodes.forEach((textNode) => {
    const source = textNode.textContent || '';
    if (!source.trim()) {
      return;
    }

    const matches =
      kind === 'audio'
        ? collectAudioMatches(source, needle, audioAssigned)
        : collectRegexMatches(source, matcher);
    if (matches.length === 0) {
      return;
    }

    const fragment = doc.createDocumentFragment();
    let cursor = 0;

    matches.forEach((match) => {
      if (match.start > cursor) {
        fragment.append(source.slice(cursor, match.start));
      }
      const marker = doc.createElement('mark');
      marker.className = `ebook-reader__inline-highlight is-${kind}`;
      if (kind === 'audio' && !audioAssigned) {
        marker.setAttribute('data-reader-audio', 'true');
        audioAssigned = true;
      }
      marker.textContent = source.slice(match.start, match.end);
      fragment.append(marker);
      cursor = match.end;
    });

    if (cursor < source.length) {
      fragment.append(source.slice(cursor));
    }

    textNode.replaceWith(fragment);
  });
}

export function collectAudioMatches(
  source: string,
  needle: string,
  alreadyAssigned: boolean,
): Array<{ start: number; end: number }> {
  if (alreadyAssigned) {
    return [];
  }
  const start = source.indexOf(needle);
  if (start < 0) {
    return [];
  }
  return [{ start, end: start + needle.length }];
}

export function collectRegexMatches(
  source: string,
  matcher: RegExp | null,
): Array<{ start: number; end: number }> {
  if (!matcher) {
    return [];
  }
  const matches: Array<{ start: number; end: number }> = [];
  for (const match of source.matchAll(matcher)) {
    const start = match.index ?? -1;
    if (start < 0) {
      continue;
    }
    matches.push({ start, end: start + match[0].length });
  }
  return matches;
}

export function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
