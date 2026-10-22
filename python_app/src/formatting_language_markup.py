"""Translate content language attributes to bounded internal language markers."""

import re


def extract_language_attributes(html_text: str) -> str:
    """
    Extract lang/xml:lang attributes from HTML tags and convert to [[lang:xx]].
    Processes only content tags (p, div, span); ignores structural tags (html, body).

    Exemplo:
        <html lang="pt"><p lang="en">Hello</p></html>
        -> <html lang="pt">[[lang:en]]<p>Hello</p>[[/lang]]</html>
    """
    if not html_text:
        return html_text

    # Structural tags that should be ignored (no [[lang:]] added)
    structural_tags = {
        "html",
        "body",
        "head",
        "article",
        "section",
        "header",
        "footer",
        "main",
        "nav",
    }

    # Process multiple times to capture nested tags
    # Start from the innermost (smallest distance between open and close)
    max_iterations = 10
    for _ in range(max_iterations):
        # Pattern to detect tags with lang attribute
        # Captures: <tag lang="xx" ...> content </tag>
        lang_pattern = re.compile(
            r'<(\w+)\s+([^>]*?)(?:lang|xml:lang)=["\']([a-zA-Z\-]+)["\']([^>]*?)>(.*?)</\1>',
            re.IGNORECASE | re.DOTALL,
        )

        match = lang_pattern.search(html_text)
        if not match:
            break  # No lang tag found

        tag_name = match.group(1).lower()
        attrs_before = match.group(2)
        lang_code = match.group(3)
        attrs_after = match.group(4)
        content = match.group(5)

        # Ignore structural tags to avoid breaking chapters
        if tag_name in structural_tags:
            # Remove only the lang attribute, do not add [[lang:]]
            attrs = (attrs_before + attrs_after).strip()
            if attrs:
                new_tag = f"<{tag_name} {attrs}>"
            else:
                new_tag = f"<{tag_name}>"

            replacement = f"{new_tag}{content}</{tag_name}>"
            html_text = html_text[: match.start()] + replacement + html_text[match.end() :]
            continue

        # Remove lang attribute and reconstruct tag without it
        attrs = (attrs_before + attrs_after).strip()
        if attrs:
            new_tag = f"<{tag_name} {attrs}>"
        else:
            new_tag = f"<{tag_name}>"

        # Add language markers around the content
        replacement = f"{new_tag}[[lang:{lang_code}]]{content}[[/lang]]</{tag_name}>"

        # Replace only the first (innermost) occurrence
        html_text = html_text[: match.start()] + replacement + html_text[match.end() :]

    return html_text
