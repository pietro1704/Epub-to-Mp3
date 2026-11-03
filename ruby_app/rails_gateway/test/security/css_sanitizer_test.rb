require "minitest/autorun"
require "rails-html-sanitizer"

class CssSanitizerTest < Minitest::Test
  def setup
    @sanitizer = Rails::HTML5::SafeListSanitizer.new
  end

  def test_preserves_allowed_css_and_removes_disallowed_properties
    assert_equal "color:red;width:12px;",
      @sanitizer.sanitize_css("color:red;position:fixed;width:12px")
  end

  def test_bad_url_cannot_hide_a_disallowed_declaration_after_an_escaped_backslash
    # A browser ends the bad URL at the first unescaped closing parenthesis.
    # GHSA-pq4g-8rxf-4g29: the old tokenizer consumed the following declaration.
    [2, 4].each do |backslash_count|
      css = 'width:calc(url(x"' + "\\" * backslash_count + ')); position:fixed; x:))'

      refute_includes @sanitizer.sanitize_css(css), "position:fixed",
        "a disallowed declaration survived after #{backslash_count} backslashes"
    end
  end
end
