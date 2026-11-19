require "test_helper"

class PreferencesTest < ActionDispatch::IntegrationTest
  test "automatic locale follows the most preferred accepted language" do
    { "pt-BR,pt;q=0.9,en;q=0.8" => "pt-BR", "pt-PT" => "pt-BR", "en-GB,pt;q=0.9" => "en-US",
      "es-ES,es;q=0.9" => "en-US", "en;q=0.4,pt-BR;q=0.9" => "pt-BR", "pt;q=0,en;q=0.1" => "en-US",
      "*" => "en-US", "" => "en-US" }.each do |accept_language, document_language|
      get "/", headers: { "Accept-Language" => accept_language }

      assert_select "html[lang='#{document_language}']", 1, accept_language.inspect
    end
  end

  test "automatic locale is English without an Accept-Language header" do
    get "/"

    assert_select "html[lang='en-US']"
  end

  test "choosing a locale re-renders every later response in it regardless of the browser language" do
    patch "/preferences", params: { locale: "en" }, headers: { "Accept-Language" => "pt-BR" }

    assert_response :see_other
    assert_redirected_to "/"
    follow_redirect! headers: { "Accept-Language" => "pt-BR" }
    assert_select "html[lang='en-US']"
    assert_select ".help-toggle button", "Help & System"
    assert_select "form[aria-label=Language] button.topbar__button--active", "English"
  end

  test "choosing automatic locale clears the stored choice" do
    patch "/preferences", params: { locale: "pt" }
    patch "/preferences", params: { locale: "auto" }

    assert_predicate cookies[:locale], :blank?
    get "/", headers: { "Accept-Language" => "en-US" }
    assert_select "html[lang='en-US']"
    assert_select "form[aria-label=Language] button.topbar__button--active", "Auto"
  end

  test "an explicit theme is rendered on the document element of the next response" do
    { "dark" => "theme-dark", "light" => "theme-light" }.each do |theme, theme_class|
      patch "/preferences", params: { theme: theme }
      follow_redirect!

      assert_select "html.#{theme_class}", 1
      assert_select "[data-controller~=theme][data-theme-mode-value=#{theme}]", 1
      assert_select "button.topbar__button--active[name=theme][value=#{theme}]", 1
    end
  end

  test "the light tokens apply unconditionally only when light was chosen" do
    get "/"
    assert_equal [ "(prefers-color-scheme: light)" ], light_stylesheet_media

    patch "/preferences", params: { theme: "light" }
    follow_redirect!
    assert_equal [ "(prefers-color-scheme: light)", "all" ], light_stylesheet_media

    patch "/preferences", params: { theme: "dark" }
    follow_redirect!
    assert_equal [ "(prefers-color-scheme: light)" ], light_stylesheet_media
  end

  test "automatic theme leaves the document element to the operating system" do
    patch "/preferences", params: { theme: "dark" }
    patch "/preferences", params: { theme: "auto" }

    assert_predicate cookies[:theme], :blank?
    get "/"
    assert_select "html.theme-dark, html.theme-light", 0
    assert_select "[data-theme-mode-value=auto]", 1
  end

  test "locale and theme can be stored by one request" do
    patch "/preferences", params: { locale: "pt", theme: "dark" }
    follow_redirect!

    assert_select "html.theme-dark[lang='pt-BR']", 1
  end

  test "reports whether a choice is already stored so the browser seeds it only once" do
    get "/"
    assert_select "form[data-preference=theme][data-storage-key=ebook-tts-theme][data-chosen=false][data-mode=auto]", 1
    assert_select "form[data-preference=locale][data-storage-key=ebook-tts-locale][data-chosen=false][data-mode=auto]", 1

    patch "/preferences", params: { locale: "pt", theme: "light" }
    follow_redirect!
    assert_select "form[data-preference=theme][data-chosen=true][data-mode=light]", 1
    assert_select "form[data-preference=locale][data-chosen=true][data-mode=pt]", 1
  end

  test "redirects back to the page that submitted the form" do
    patch "/preferences", params: { theme: "dark" }, headers: { "Referer" => "http://www.example.com/?tab=progress" }

    assert_redirected_to "http://www.example.com/?tab=progress"
  end

  test "rejects unknown values without storing anything" do
    patch "/preferences", params: { locale: "es", theme: "sepia" }

    assert_response :unprocessable_content
    assert_predicate cookies[:locale], :blank?
    assert_predicate cookies[:theme], :blank?
  end

  test "ignores a tampered cookie value" do
    cookies[:locale] = "es"
    cookies[:theme] = "sepia"

    get "/", headers: { "Accept-Language" => "pt-BR" }

    assert_select "html[lang='pt-BR']"
    assert_select "html.theme-sepia", 0
    assert_select "[data-theme-mode-value=auto]", 1
  end

  test "requires the authenticity token of the rendered form" do
    with_forgery_protection do
      get "/"
      token = css_select("form[action='/preferences'] input[name=authenticity_token]").first["value"]

      patch "/preferences", params: { theme: "dark" }
      assert_response :unprocessable_content
      assert_predicate cookies[:theme], :blank?

      patch "/preferences", params: { theme: "dark", authenticity_token: token }
      assert_response :see_other
      assert_equal "dark", cookies[:theme]
    end
  end

  private

  def light_stylesheet_media
    css_select("link[rel=stylesheet][href*=theme_light]").map { |link| link["media"] }
  end
end
