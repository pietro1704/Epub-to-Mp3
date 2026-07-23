from src.reader_sanitizer import sanitize_reader_css, sanitize_reader_html


def test_sanitize_reader_html_removes_active_content_and_preserves_reader_markup():
    markup = """
    <article id="chapter" onclick="alert(1)">
      <h1>Chapter title</h1>
      <p class="lead">Safe <strong>content</strong>.</p>
      <script>alert(2)</script>
      <img src="cover.jpg" alt="Cover" onerror="alert(3)">
      <a href="javascript:alert(4)" title="safe">Link</a>
      <a href="#chapter">Internal link</a>
      <iframe src="https://evil.example"></iframe>
    </article>
    """

    sanitized = sanitize_reader_html(markup)

    assert "<script" not in sanitized.lower()
    assert "iframe" not in sanitized.lower()
    assert "onclick" not in sanitized.lower()
    assert "onerror" not in sanitized.lower()
    assert "javascript:" not in sanitized.lower()
    assert "Chapter title" in sanitized
    assert "<strong>content</strong>" in sanitized
    assert 'src="cover.jpg"' in sanitized
    assert 'href="#chapter"' in sanitized


def test_sanitize_reader_css_removes_active_constructs_and_keeps_safe_declarations():
    css = """
    .lead { color: #123456; font-weight: 700; background-image: url(javascript:alert(1)); }
    @import url(https://evil.example/style.css);
    .x { behavior: url(evil.htc); width: expression(alert(1)); display: block; }
    </style><script>alert(1)</script>
    """

    sanitized = sanitize_reader_css(css)

    assert "@import" not in sanitized.lower()
    assert "javascript:" not in sanitized.lower()
    assert "expression" not in sanitized.lower()
    assert "behavior" not in sanitized.lower()
    assert "</style" not in sanitized.lower()
    assert "<script" not in sanitized.lower()
    assert "color: #123456" in sanitized
    assert "font-weight: 700" in sanitized
    assert "display: block" in sanitized
