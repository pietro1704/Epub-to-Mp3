const ALLOWED_TAGS = new Set([
  "A",
  "ABBR",
  "ARTICLE",
  "B",
  "BLOCKQUOTE",
  "BR",
  "CAPTION",
  "CITE",
  "CODE",
  "DD",
  "DIV",
  "DL",
  "DT",
  "EM",
  "FIGCAPTION",
  "FIGURE",
  "H1",
  "H2",
  "H3",
  "H4",
  "H5",
  "H6",
  "HR",
  "I",
  "IMG",
  "LI",
  "MARK",
  "OL",
  "P",
  "PRE",
  "Q",
  "S",
  "SMALL",
  "SPAN",
  "STRONG",
  "SUB",
  "SUP",
  "TABLE",
  "TBODY",
  "TD",
  "TFOOT",
  "TH",
  "THEAD",
  "TR",
  "U",
  "UL",
]);
const REMOVE_ENTIRELY = new Set([
  "SCRIPT",
  "STYLE",
  "IFRAME",
  "OBJECT",
  "EMBED",
  "FORM",
  "INPUT",
  "BUTTON",
  "TEXTAREA",
  "SELECT",
  "VIDEO",
  "AUDIO",
  "SOURCE",
  "LINK",
  "META",
]);
const GLOBAL_ATTRIBUTES = new Set([
  "id",
  "class",
  "lang",
  "title",
  "dir",
  "style",
]);
const TAG_ATTRIBUTES: Record<string, Set<string>> = {
  A: new Set(["href", "title", "id", "class", "lang"]),
  IMG: new Set(["src", "alt", "title", "width", "height", "id", "class"]),
};
const SAFE_CSS_PROPERTIES = new Set([
  "background-color",
  "border",
  "border-bottom",
  "border-color",
  "border-left",
  "border-radius",
  "border-right",
  "border-spacing",
  "border-style",
  "border-top",
  "border-width",
  "color",
  "display",
  "float",
  "font-family",
  "font-size",
  "font-style",
  "font-variant",
  "font-weight",
  "height",
  "letter-spacing",
  "line-height",
  "margin",
  "margin-bottom",
  "margin-left",
  "margin-right",
  "margin-top",
  "max-height",
  "max-width",
  "min-height",
  "min-width",
  "opacity",
  "padding",
  "padding-bottom",
  "padding-left",
  "padding-right",
  "padding-top",
  "text-align",
  "text-decoration",
  "text-indent",
  "text-transform",
  "vertical-align",
  "white-space",
  "width",
]);
const DANGEROUS_CSS =
  /(?:expression|behavior|-moz-binding|javascript\s*:|vbscript\s*:|data\s*:\s*text\/html|@import|url\s*\()/i;

function isSafeUrl(value: string): boolean {
  const normalized = value.trim().replaceAll("\0", "").toLowerCase();
  if (normalized.startsWith("//")) return false;
  try {
    return ["", "http:", "https:", "mailto:"].includes(
      new URL(normalized, window.location.href).protocol,
    );
  } catch {
    return false;
  }
}

export function sanitizeReaderCss(css: string | null | undefined): string {
  if (typeof css !== "string") return "";
  const output: string[] = [];
  const withoutComments = css.replace(/\/\*[\s\S]*?\*\//g, "");
  for (const match of withoutComments.matchAll(/([^{}@]+)\{([^{}]*)\}/g)) {
    const declarations: string[] = [];
    for (const declaration of match[2].split(";")) {
      const separator = declaration.indexOf(":");
      if (separator < 0) continue;
      const property = declaration.slice(0, separator).trim().toLowerCase();
      const value = declaration.slice(separator + 1).trim();
      if (
        !SAFE_CSS_PROPERTIES.has(property) ||
        !value ||
        DANGEROUS_CSS.test(value) ||
        value.includes("<") ||
        value.includes(">")
      ) {
        continue;
      }
      declarations.push(`${property}: ${value}`);
    }
    if (declarations.length > 0) {
      output.push(`${match[1].trim()} { ${declarations.join("; ")}; }`);
    }
  }
  return output.join("\n");
}

export function sanitizeReaderHtml(markup: string | null | undefined): string {
  if (typeof markup !== "string") return "";
  const template = document.createElement("template");
  template.innerHTML = markup;
  const elements = Array.from(template.content.querySelectorAll("*"));
  for (const element of elements) {
    const tag = element.tagName;
    if (REMOVE_ENTIRELY.has(tag)) {
      element.remove();
      continue;
    }
    if (!ALLOWED_TAGS.has(tag)) {
      element.replaceWith(...Array.from(element.childNodes));
      continue;
    }
    const allowed = new Set([
      ...GLOBAL_ATTRIBUTES,
      ...(TAG_ATTRIBUTES[tag] ?? []),
    ]);
    for (const attribute of Array.from(element.attributes)) {
      const name = attribute.name.toLowerCase();
      if (name.startsWith("on") || !allowed.has(name)) {
        element.removeAttribute(attribute.name);
      } else if (
        (name === "href" || name === "src") &&
        !isSafeUrl(attribute.value)
      ) {
        element.removeAttribute(attribute.name);
      } else if (name === "style") {
        const style = sanitizeReaderCss(`x { ${attribute.value} }`)
          .replace(/^x\s*\{\s*/i, "")
          .replace(/\s*}\s*$/, "");
        if (style) element.setAttribute("style", style);
        else element.removeAttribute("style");
      }
    }
  }
  return template.innerHTML;
}
