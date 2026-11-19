module ApplicationHelper
  LIGHT_SCHEME_MEDIA = "(prefers-color-scheme: light)".freeze

  def application_version = Rails.configuration.x.application_version

  def converter_runtime_base_path = Rails.configuration.x.converter_runtime.tree.base_path

  # The fixture synthesis module for conversion system tests. Nil outside the
  # test environment, so production pages never name or ship it.
  def conversion_test_fixture_path = Rails.env.test? && ENV["REAL_BROWSER_MODEL"] != "1" ? asset_path("conversion_fixture.js") : nil

  # An explicit choice is rendered on the first byte; "auto" leaves the class
  # to the stylesheet media query and the theme controller.
  def theme_class = theme_mode == ViewerPreferences::AUTOMATIC ? nil : "theme-#{theme_mode}"

  # The light tokens follow the operating system unless light was chosen,
  # in which case a second link applies them unconditionally.
  def theme_stylesheet_tags
    tags = [ stylesheet_link_tag("theme_tokens", "application_shell", "navigation_panels", "overlays", "book_picker", "reader", "conversion") ]
    tags << stylesheet_link_tag("theme_light", media: LIGHT_SCHEME_MEDIA)
    tags << stylesheet_link_tag("theme_light", media: "all") if theme_mode == "light"
    safe_join(tags, "\n")
  end
end
