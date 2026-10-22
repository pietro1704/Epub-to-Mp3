export function stripHtml(value: string): string {
  return value
    .replace(/<[^>]+>/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

export function sanitizeReaderTree(root: HTMLElement, doc: Document): void {
  const allowedTags = new Set([
    'a',
    'blockquote',
    'br',
    'code',
    'div',
    'em',
    'figcaption',
    'figure',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'hr',
    'i',
    'li',
    'mark',
    'ol',
    'p',
    'pre',
    'section',
    'small',
    'span',
    'strong',
    'sub',
    'sup',
    'u',
    'ul',
  ]);
  const allowedStyleProps = new Set([
    'font-style',
    'font-weight',
    'font-family',
    'font-size',
    'text-align',
    'text-decoration',
    'text-transform',
    'letter-spacing',
    'margin-left',
    'margin-right',
    'padding-left',
    'padding-right',
  ]);
  const elements = Array.from(root.querySelectorAll('*'));

  elements.forEach((element) => {
    const tag = element.tagName.toLowerCase();
    if (tag === 'script' || tag === 'style' || tag === 'iframe') {
      element.remove();
      return;
    }
    if (tag === 'img' || tag === 'svg' || tag === 'canvas') {
      const alt = element.getAttribute('alt')?.trim();
      if (alt) {
        const fallback = doc.createElement('p');
        fallback.textContent = alt;
        fallback.className = 'ebook-reader__media-note';
        element.replaceWith(fallback);
      } else {
        element.remove();
      }
      return;
    }
    if (!allowedTags.has(tag)) {
      element.replaceWith(...Array.from(element.childNodes));
      return;
    }

    Array.from(element.attributes).forEach((attribute) => {
      const name = attribute.name.toLowerCase();
      if (name.startsWith('on')) {
        element.removeAttribute(attribute.name);
        return;
      }
      if (name === 'href') {
        const value = attribute.value.trim();
        if (
          value &&
          !value.startsWith('#') &&
          !/^https?:\/\//i.test(value) &&
          !/^mailto:/i.test(value)
        ) {
          element.removeAttribute(attribute.name);
        }
        return;
      }
      if (name === 'style') {
        const style = attribute.value
          .split(';')
          .map((entry) => entry.trim())
          .filter(Boolean)
          .map((entry) => {
            const [prop, ...rest] = entry.split(':');
            return [prop?.trim().toLowerCase(), rest.join(':').trim()] as const;
          })
          .filter(([prop, value]) => prop && value && allowedStyleProps.has(prop))
          .map(([prop, value]) => `${prop}: ${value}`);
        if (style.length > 0) {
          element.setAttribute('style', style.join('; '));
        } else {
          element.removeAttribute('style');
        }
        return;
      }
      if (name === 'class') {
        return;
      }
      if (name === 'id') {
        return;
      }
      if (!['href', 'style', 'title', 'class', 'id'].includes(name)) {
        element.removeAttribute(attribute.name);
      }
    });
  });
}

export function escapeHtml(value: string): string {
  return value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
}
